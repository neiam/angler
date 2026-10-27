defmodule AnglerWeb.LoginThrottle do
  @moduledoc """
  Failed-password throttle shared by every password entry point: the login
  LiveView's live check, `SessionController.create/2` and the OAuth
  password grant.

  Keyed on the lowercased handle plus client IP, like upstream's
  `email|ip` throttle, with upstream's budget of 5 failures an hour.
  The IP is the real client's: `AnglerWeb.Plugs.RemoteIp` resolves the
  ingress proxy's `X-Forwarded-For` for HTTP requests, and the login
  LiveView does the same for its socket, so a stranger's failures lock
  out only the stranger's address, not the account.
  """

  alias Angler.Accounts
  alias Angler.RateLimit

  @limit 5
  @window_s 3600

  @spec key(Plug.Conn.t() | :inet.ip_address() | nil, String.t()) :: term()
  def key(%Plug.Conn{remote_ip: ip}, handle), do: key(ip, handle)
  def key(ip, handle) when is_binary(handle), do: {:login, String.downcase(handle), ip}

  @spec allowed?(term()) :: boolean()
  def allowed?(key), do: RateLimit.allowed?(key, @limit, @window_s)

  @spec failed(term()) :: :ok
  def failed(key), do: RateLimit.fail(key, @window_s)

  @spec succeeded(term()) :: :ok
  def succeeded(key), do: RateLimit.reset(key)

  @doc "`Accounts.authenticate/2` behind the throttle."
  @spec authenticate(term(), String.t(), String.t()) ::
          {:ok, Accounts.User.t()} | :error | :rate_limited
  def authenticate(key, handle, password) do
    if allowed?(key) do
      case Accounts.authenticate(handle, password) do
        {:ok, _} = ok ->
          succeeded(key)
          ok

        :error ->
          failed(key)
          :error
      end
    else
      :rate_limited
    end
  end
end
