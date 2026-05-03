defmodule Angler.Media.Workers.ImageProcess do
  @moduledoc """
  Process a freshly uploaded image asset:

    * Read dimensions via `mogrify identify`.
    * Strip EXIF.
    * Generate `preview` (1024×1024 fit) and `thumb` (640×640 fit) variants.
    * Compute a blurhash from a 32×32 downscale.
    * Mark the row `:ready` with paths set.

  Failures (corrupt input, mogrify error) flip the row to `:failed` and the
  file is left in place for forensic inspection.
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
      nil ->
        :ok

      %Asset{status: "ready"} ->
        :ok

      %Asset{} = asset ->
        do_process(asset)
    end
  end

  defp do_process(%Asset{} = asset) do
    abs_original = Path.join(Angler.Media.Storage.Local.root(), asset.path_original)

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
      e ->
        require Logger
        Logger.warning("ImageProcess failed for asset #{asset.id}: #{inspect(e)}")

        asset
        |> Ecto.Changeset.change(status: "failed")
        |> Repo.update()

        {:error, e}
    end
  end

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
    # Use ImageMagick to dump a 32x32 raw RGB byte-stream to stdout, then
    # feed those bytes directly to BlurHash.encode/5.
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
end
