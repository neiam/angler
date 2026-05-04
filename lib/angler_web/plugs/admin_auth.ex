defmodule AnglerWeb.Plugs.AdminAuth do
  @moduledoc """
  Admin/moderator gate. Layered on top of `BearerAuth`: the bearer must
  resolve to a `User` with `is_admin: true` (default) or, when
  `role: :moderator` is passed, either `is_admin` or `is_moderator`.

  ## Usage

      pipeline :admin do
        plug AnglerWeb.Plugs.BearerAuth, scopes: ["admin:read"]
        plug AnglerWeb.Plugs.AdminAuth
      end

      pipeline :admin_write do
        plug AnglerWeb.Plugs.BearerAuth, scopes: ["admin:write"]
        plug AnglerWeb.Plugs.AdminAuth
      end

  Mastodon's `admin:read`/`admin:write` scopes piggyback on the regular OAuth
  scope check via BearerAuth; AdminAuth is the role check on top.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: %{role: Keyword.get(opts, :role, :admin)}

  @impl Plug
  def call(conn, %{role: role}) do
    case AnglerWeb.Plugs.BearerAuth.current_scope(conn) do
      %{user: user} when not is_nil(user) ->
        if role_ok?(user, role), do: conn, else: forbidden(conn)

      _ ->
        forbidden(conn)
    end
  end

  defp role_ok?(user, :admin), do: user.is_admin == true
  defp role_ok?(user, :moderator), do: user.is_admin == true or user.is_moderator == true
  defp role_ok?(_, _), do: false

  defp forbidden(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode_to_iodata!(%{"error" => "Insufficient privileges"}))
    |> halt()
  end
end
