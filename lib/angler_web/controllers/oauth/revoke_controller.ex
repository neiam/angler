defmodule AnglerWeb.OAuth.RevokeController do
  @moduledoc """
  POST /oauth/revoke — RFC 7009 token revocation.

  Body: `token=...&client_id=...&client_secret=...`. Always returns 200 per
  spec, regardless of whether the token existed or was already revoked.
  """

  use AnglerWeb, :controller

  alias Angler.OAuth

  def revoke(conn, params) do
    token = params["token"]
    client = OAuth.get_client(params["client_id"])

    cond do
      not is_binary(token) or token == "" ->
        send_resp(conn, 200, "")

      client && not OAuth.verify_client_secret(client, params["client_secret"]) ->
        # Per RFC 7009 we still 200, but don't actually revoke when the
        # client can't authenticate.
        send_resp(conn, 200, "")

      true ->
        OAuth.revoke_raw_token(token, client)
        send_resp(conn, 200, "")
    end
  end
end
