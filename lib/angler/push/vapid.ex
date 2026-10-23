defmodule Angler.Push.Vapid do
  @moduledoc """
  Helper around the instance's VAPID config.

  At runtime we read from `config :angler, :vapid_details` —
  set in `runtime.exs` from environment variables (`PUSH_VAPID_PUBLIC_KEY`,
  `PUSH_VAPID_PRIVATE_KEY`, `PUSH_VAPID_SUBJECT`). When the keys aren't configured,
  `enabled?/0` returns false and push delivery becomes a no-op.

  `generate/0` produces a fresh ES256 keypair URL-safe-base64-encoded —
  use it once when standing up a new instance, save the result to env vars,
  redeploy.
  """

  @doc "Whether VAPID is configured (so push delivery can run)."
  @spec enabled?() :: boolean()
  def enabled? do
    pub = get_key(:public_key)
    priv = get_key(:private_key)
    is_binary(pub) and is_binary(priv) and byte_size(pub) > 0 and byte_size(priv) > 0
  end

  @doc "URL-safe-base64 of the VAPID public key, or nil when unconfigured."
  @spec public_key() :: String.t() | nil
  def public_key, do: get_key(:public_key)

  defp get_key(k) do
    case Application.get_env(:angler, :vapid_details) do
      v when is_list(v) -> Keyword.get(v, k)
      v when is_map(v) -> Map.get(v, k)
      _ -> nil
    end
  end

  @doc """
  Generate a fresh ES256 P-256 keypair returned as `%{public_key, private_key}`
  with URL-safe-base64 encoded values, suitable for VAPID config.
  """
  @spec generate() :: %{public_key: String.t(), private_key: String.t()}
  def generate do
    {pub, priv} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      public_key: Base.url_encode64(pub, padding: false),
      private_key: Base.url_encode64(priv, padding: false)
    }
  end
end
