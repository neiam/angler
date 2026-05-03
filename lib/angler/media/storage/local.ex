defmodule Angler.Media.Storage.Local do
  @moduledoc """
  Local-disk storage backend.

  Layout (root configurable via `:angler, :media_root`):

      <root>/m/v2/<profile_id>/<sha-prefix>/<filename>

  Public URL is `<endpoint>/storage/m/v2/<profile_id>/<sha-prefix>/<filename>`,
  served by `AnglerWeb.MediaController.serve/2`.
  """

  @behaviour Angler.Media.Storage

  alias Angler.Media.Asset

  @impl true
  def put(profile_id, _variant, filename, source) do
    path = relative_path(profile_id, filename)
    abs = Path.join(root(), path)
    File.mkdir_p!(Path.dirname(abs))

    cond do
      is_binary(source) and File.exists?(source) ->
        File.cp!(source, abs)

      is_binary(source) ->
        File.write!(abs, source)
    end

    {:ok, path}
  end

  @impl true
  def url(%Asset{} = asset, variant) do
    case path_for(asset, variant) do
      nil -> nil
      path -> AnglerWeb.Endpoint.url() <> "/storage/" <> path
    end
  end

  @impl true
  def delete(path) when is_binary(path) do
    abs = Path.join(root(), path)
    _ = File.rm(abs)
    :ok
  end

  ## Internals

  def root do
    Application.get_env(:angler, :media_root) ||
      Path.join([System.tmp_dir!(), "angler-media"])
  end

  defp path_for(%Asset{path_original: p}, :original) when is_binary(p), do: p
  defp path_for(%Asset{path_thumb: p}, :thumb) when is_binary(p), do: p
  defp path_for(%Asset{path_preview: p}, :preview) when is_binary(p), do: p
  defp path_for(_, _), do: nil

  defp relative_path(profile_id, filename) do
    prefix = String.slice(filename, 0, 2)
    Path.join(["m", "v2", Integer.to_string(profile_id), prefix, filename])
  end
end
