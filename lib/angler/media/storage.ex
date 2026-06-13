defmodule Angler.Media.Storage do
  @moduledoc """
  Behaviour for storing media bytes. Implementations:

    * `Angler.Media.Storage.Local` (default) — writes to a configured directory
      and serves through the `/storage/m/v2/...` endpoint.

  Future: `Angler.Media.Storage.S3`. Operators choose via
  `config :angler, :media_storage, Angler.Media.Storage.Local`.
  """

  alias Angler.Media.Asset

  @callback put(
              profile_id :: integer(),
              variant :: atom(),
              filename :: String.t(),
              source :: Path.t() | binary()
            ) :: {:ok, String.t()} | {:error, term()}

  @callback url(Asset.t(), variant :: atom()) :: String.t() | nil

  @callback delete(path :: String.t()) :: :ok

  ## Convenience proxies — delegate to the configured backend.

  # `media_storage` may be configured either as a short name (`:local` / `:s3`,
  # as `config/runtime.exs` sets from MEDIA_STORAGE) or as an explicit backend
  # module. Normalize both to a module so `backend().put(...)` always resolves.
  def backend do
    case Application.get_env(:angler, :media_storage, Angler.Media.Storage.Local) do
      :local -> Angler.Media.Storage.Local
      :s3 -> Angler.Media.Storage.S3
      module when is_atom(module) -> module
    end
  end

  def put(profile_id, variant, filename, source),
    do: backend().put(profile_id, variant, filename, source)

  def url(%Asset{} = asset, variant), do: backend().url(asset, variant)

  def delete(path) when is_binary(path), do: backend().delete(path)
end
