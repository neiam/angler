defmodule Angler.Stories.RemoteMedia do
  @moduledoc """
  Downloads a remote story's media and stores it locally, as upstream
  StoryFetch::downloadAndValidateMedia does, rather than hotlinking it:

    * the URL's extension must be one we take;
    * the bytes come through `Angler.Federation.HTTP.download/2` (SSRF
      guards, size cap of upstream's default `max_photo_size`, 15000 KB);
    * the sniffed type must be the declared `mediaType` (upstream's finfo
      check), and an image must be exactly 1080x1920;
    * the file lands in `Angler.Media.Storage` under a random name.

  Stories mirrored before downloads existed keep their remote URL as
  `path`; `hotlinked?/1` tells them apart.
  """

  import Bitwise

  alias Angler.Federation.HTTP
  alias Angler.Media.Storage

  @max_bytes 15_000 * 1024
  @width 1080
  @height 1920

  @extensions %{
    "image/jpeg" => ~w(jpg jpeg),
    "image/png" => ~w(png),
    "image/gif" => ~w(gif),
    "image/webp" => ~w(webp),
    "image/avif" => ~w(avif),
    "video/mp4" => ~w(mp4),
    "video/webm" => ~w(webm)
  }

  @doc "Download, check and store the media at `url`, declared as `mime`."
  @spec fetch(String.t(), String.t(), integer()) :: {:ok, String.t()} | {:error, term()}
  def fetch(url, mime, profile_id) when is_binary(url) and is_binary(mime) do
    with {:ok, exts} <- Map.fetch(@extensions, mime),
         true <- extension(url) in Enum.concat(Map.values(@extensions)),
         {:ok, bytes} <- HTTP.download(url, max_bytes: @max_bytes, accept: mime),
         ^mime <- sniff(bytes),
         :ok <- check(mime, bytes) do
      store(profile_id, hd(exts), bytes)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_media}
    end
  end

  @doc "Whether a story's `path` is a hotlinked remote URL, not a stored file."
  @spec hotlinked?(String.t() | nil) :: boolean()
  def hotlinked?(path) when is_binary(path),
    do: String.starts_with?(path, ["http://", "https://"])

  def hotlinked?(_), do: false

  @doc "Delete a stored remote story file; hotlinked ones have none."
  @spec delete(String.t() | nil) :: :ok
  def delete(path) when is_binary(path) do
    if hotlinked?(path), do: :ok, else: Storage.delete(path)
  end

  def delete(_), do: :ok

  ## Internals

  defp extension(url) do
    case URI.parse(url).path do
      path when is_binary(path) ->
        path |> Path.extname() |> String.trim_leading(".") |> String.downcase()

      _ ->
        ""
    end
  end

  defp check("image/" <> _, bytes) do
    if dimensions(bytes) == {@width, @height}, do: :ok, else: :error
  end

  defp check("video/" <> _, bytes) when byte_size(bytes) > 0, do: :ok
  defp check(_, _), do: :error

  defp store(profile_id, ext, bytes) do
    name = "story-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower) <> "." <> ext
    tmp = Path.join(System.tmp_dir!(), "angler-" <> name)

    try do
      File.write!(tmp, bytes)
      Storage.put(profile_id, :story, name, tmp)
    after
      File.rm(tmp)
    end
  end

  @doc false
  # The media type by magic bytes, for the types we take.
  @spec sniff(binary()) :: String.t() | nil
  def sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  def sniff(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>), do: "image/png"
  def sniff(<<"GIF8", v, "a", _::binary>>) when v in [?7, ?9], do: "image/gif"
  def sniff(<<"RIFF", _::32, "WEBP", _::binary>>), do: "image/webp"

  def sniff(<<_::32, "ftyp", brand::binary-4, _::binary>>) when brand in ["avif", "avis"],
    do: "image/avif"

  def sniff(<<_::32, "ftyp", _::binary>>), do: "video/mp4"
  def sniff(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: "video/webm"
  def sniff(_), do: nil

  @doc false
  # `{width, height}` from an image header, or nil.
  @spec dimensions(binary()) :: {pos_integer(), pos_integer()} | nil
  def dimensions(<<0x89, "PNG\r\n", 0x1A, "\n", _::32, "IHDR", w::32, h::32, _::binary>>),
    do: {w, h}

  def dimensions(<<"GIF8", _, "a", w::little-16, h::little-16, _::binary>>), do: {w, h}

  def dimensions(
        <<"RIFF", _::32, "WEBP", "VP8X", _::32, _::32, w::little-24, h::little-24, _::binary>>
      ),
      do: {w + 1, h + 1}

  def dimensions(<<"RIFF", _::32, "WEBP", "VP8L", _::32, 0x2F, bits::little-32, _::binary>>) do
    {(bits &&& 0x3FFF) + 1, (bits >>> 14 &&& 0x3FFF) + 1}
  end

  def dimensions(
        <<"RIFF", _::32, "WEBP", "VP8 ", _::32, _::24, 0x9D, 0x01, 0x2A, w::little-16,
          h::little-16, _::binary>>
      ) do
    {w &&& 0x3FFF, h &&& 0x3FFF}
  end

  def dimensions(<<0xFF, 0xD8, rest::binary>>), do: jpeg_dimensions(rest)

  def dimensions(<<_::32, "ftyp", _::binary>> = avif) do
    case :binary.match(avif, "ispe") do
      {at, _} ->
        case binary_part(avif, at, min(16, byte_size(avif) - at)) do
          <<"ispe", _::32, w::32, h::32>> -> {w, h}
          _ -> nil
        end

      :nomatch ->
        nil
    end
  end

  def dimensions(_), do: nil

  # Walk the JPEG segments to the first start-of-frame marker (C0–CF, bar
  # DHT C4, JPG C8 and DAC CC).
  defp jpeg_dimensions(<<0xFF, marker, _len::16, _precision, h::16, w::16, _::binary>>)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC],
       do: {w, h}

  defp jpeg_dimensions(<<0xFF, 0xFF, rest::binary>>), do: jpeg_dimensions(<<0xFF, rest::binary>>)

  defp jpeg_dimensions(<<0xFF, marker, len::16, rest::binary>>)
       when marker not in [0xD8, 0xD9, 0xDA] and len >= 2 and byte_size(rest) >= len - 2 do
    next = binary_part(rest, len - 2, byte_size(rest) - len + 2)
    jpeg_dimensions(next)
  end

  defp jpeg_dimensions(_), do: nil
end
