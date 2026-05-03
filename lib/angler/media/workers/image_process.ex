defmodule Angler.Media.Workers.ImageProcess do
  @moduledoc """
  Asset processor — branches on `media_type`.

    * `image/*` — mogrify resize (preview 1024px, thumb 640px), EXIF strip,
      blurhash from a 32×32 raw-RGB pipe.
    * `video/*` — `ffprobe` for width / height / duration; `ffmpeg` poster
      frame at 1s rendered to a JPEG used as `path_preview`. We currently
      do not transcode; the original is served as-is.

  Failures (corrupt input, tool error) flip the row to `:failed` and the
  file is left in place for forensic inspection.

  Module name kept as `ImageProcess` to avoid migration-history churn; the
  enqueue site addresses any asset type.
  """

  use Oban.Worker, queue: :media, max_attempts: 3

  alias Angler.Media.Asset
  alias Angler.Media.Storage
  alias Angler.Repo

  def enqueue(asset_id) when is_integer(asset_id) do
    %{"asset_id" => asset_id} |> __MODULE__.new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"asset_id" => id}}) do
    case Repo.get(Asset, id) do
      nil -> :ok
      %Asset{status: "ready"} -> :ok
      %Asset{} = asset -> dispatch(asset)
    end
  end

  defp dispatch(%Asset{media_type: "image/" <> _} = asset), do: process_image(asset)
  defp dispatch(%Asset{media_type: "video/" <> _} = asset), do: process_video(asset)
  defp dispatch(asset), do: mark_failed(asset, :unsupported_type)

  ## Image branch

  defp process_image(%Asset{} = asset) do
    abs_original = Path.join(Storage.Local.root(), asset.path_original)

    try do
      {width, height} = identify_dims(abs_original)
      preview_path = derive_variant(asset, abs_original, "_preview", 1024)
      thumb_path = derive_variant(asset, abs_original, "_thumb", 640)
      blur = compute_blurhash(abs_original)
      strip_exif(abs_original)

      asset
      |> Ecto.Changeset.change(
        status: "ready",
        width: width,
        height: height,
        path_preview: preview_path,
        path_thumb: thumb_path,
        blurhash: blur
      )
      |> Repo.update()
    rescue
      e -> mark_failed(asset, e)
    end
  end

  ## Video branch

  defp process_video(%Asset{} = asset) do
    abs_original = Path.join(Storage.Local.root(), asset.path_original)

    try do
      %{width: width, height: height, duration_ms: duration_ms} = ffprobe(abs_original)
      poster_path = extract_poster(asset, abs_original)
      blur = if poster_path, do: blurhash_from_poster(poster_path), else: nil

      asset
      |> Ecto.Changeset.change(
        status: "ready",
        width: width,
        height: height,
        duration_ms: duration_ms,
        path_preview: poster_path,
        path_thumb: poster_path,
        blurhash: blur
      )
      |> Repo.update()
    rescue
      e -> mark_failed(asset, e)
    end
  end

  defp ffprobe(abs) do
    args = [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=width,height,duration",
      "-of",
      "json",
      abs
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {out, 0} ->
        case Jason.decode(out) do
          {:ok, %{"streams" => [stream | _]}} ->
            %{
              width: get_int(stream, "width"),
              height: get_int(stream, "height"),
              duration_ms: parse_duration_ms(stream["duration"])
            }

          _ ->
            %{width: nil, height: nil, duration_ms: nil}
        end

      {err, code} ->
        raise "ffprobe failed (#{code}): #{err}"
    end
  end

  defp get_int(%{} = m, key) do
    case Map.get(m, key) do
      n when is_integer(n) -> n
      n when is_binary(n) -> elem(Integer.parse(n), 0)
      _ -> nil
    end
  end

  defp parse_duration_ms(nil), do: nil

  defp parse_duration_ms(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> trunc(f * 1000)
      :error -> nil
    end
  end

  defp parse_duration_ms(_), do: nil

  defp extract_poster(%Asset{} = asset, abs_original) do
    src_filename = Path.basename(asset.path_original)
    {base, _ext} = split_ext(src_filename)
    out_filename = base <> "_poster.jpg"

    tmp = Path.join(System.tmp_dir!(), "angler-poster-#{System.unique_integer([:positive])}.jpg")

    args = [
      "-y",
      "-i",
      abs_original,
      "-frames:v",
      "1",
      "-q:v",
      "2",
      tmp
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} ->
        {:ok, stored} = Storage.put(asset.profile_id, :poster, out_filename, tmp)
        File.rm(tmp)
        stored

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp blurhash_from_poster(rel_path) do
    abs = Path.join(Storage.Local.root(), rel_path)
    if File.exists?(abs), do: compute_blurhash(abs), else: nil
  end

  ## Common helpers

  defp identify_dims(path) do
    img = Mogrify.open(path) |> Mogrify.verbose()
    {img.width, img.height}
  end

  defp derive_variant(asset, src_abs, suffix, max_dim) do
    src_filename = Path.basename(asset.path_original)
    {base, ext} = split_ext(src_filename)
    out_filename = base <> suffix <> ext

    {:ok, variant_path} =
      Storage.put(asset.profile_id, :variant, out_filename, fn_make_variant(src_abs, max_dim))

    variant_path
  end

  defp fn_make_variant(src_abs, max_dim) do
    tmp = Path.join(System.tmp_dir!(), "angler-variant-#{System.unique_integer([:positive])}")
    File.cp!(src_abs, tmp)

    Mogrify.open(tmp)
    |> Mogrify.resize_to_limit("#{max_dim}x#{max_dim}")
    |> Mogrify.custom("strip")
    |> Mogrify.save(in_place: true)

    tmp
  end

  defp strip_exif(abs) do
    Mogrify.open(abs)
    |> Mogrify.custom("strip")
    |> Mogrify.save(in_place: true)
  end

  defp compute_blurhash(abs) do
    case System.cmd(
           "convert",
           [
             abs,
             "-resize",
             "32x32^",
             "-gravity",
             "center",
             "-extent",
             "32x32",
             "-depth",
             "8",
             "RGB:-"
           ],
           stderr_to_stdout: true
         ) do
      {bytes, 0} when byte_size(bytes) >= 32 * 32 * 3 ->
        pixels = :binary.bin_to_list(:binary.part(bytes, 0, 32 * 32 * 3))
        BlurHash.encode(pixels, 32, 32, 4, 3)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp split_ext(filename) do
    case Path.extname(filename) do
      "" -> {filename, ""}
      ext -> {Path.rootname(filename), ext}
    end
  end

  defp mark_failed(%Asset{} = asset, e) do
    require Logger
    Logger.warning("Asset processing failed for #{asset.id}: #{inspect(e)}")

    asset
    |> Ecto.Changeset.change(status: "failed")
    |> Repo.update()

    {:error, e}
  end
end
