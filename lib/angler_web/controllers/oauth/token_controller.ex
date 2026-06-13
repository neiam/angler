defmodule AnglerWeb.OAuth.TokenController do
  @moduledoc """
  POST /oauth/token — RFC 6749 token endpoint.

  Dispatches by `grant_type`:

    * `authorization_code` — redeems a code minted via `/oauth/authorize`
    * `password` — resource-owner password credentials
    * `client_credentials` — anonymous app token (`user_id = null`)
    * `refresh_token` — only when refresh tokens are enabled
  """

  use AnglerWeb, :controller

  alias Angler.OAuth
  alias Angler.OAuth.Client

  def token(conn, params) do
    case Map.get(params, "grant_type") do
      "authorization_code" -> authorization_code(conn, params)
      "password" -> password(conn, params)
      "client_credentials" -> client_credentials(conn, params)
      "refresh_token" -> refresh(conn, params)
      _ -> send_error(conn, "unsupported_grant_type")
    end
  end

  defp authorization_code(conn, params) do
    with {:ok, client} <- authenticate_client(params, allow_public: true),
         {:ok, code} <- fetch_required(params, "code"),
         {:ok, redirect_uri} <- fetch_required(params, "redirect_uri"),
         {:ok, %{token: token, access: access, refresh: refresh}} <-
           OAuth.redeem_authorization_code(code, client, redirect_uri, params["code_verifier"]) do
      send_token(conn, token, access, refresh)
    else
      {:error, reason} -> send_error(conn, reason)
    end
  end

  defp password(conn, params) do
    with {:ok, client} <- authenticate_client(params, allow_public: false),
         {:ok, username} <- fetch_required(params, "username"),
         {:ok, password} <- fetch_required(params, "password") do
      scopes = parse_scopes(params["scope"], client.scopes)

      case OAuth.issue_password_token(username, password, client, scopes) do
        {:ok, %{token: token, access: access, refresh: refresh}} ->
          send_token(conn, token, access, refresh)

        {:error, reason} ->
          send_error(conn, reason)
      end
    else
      {:error, reason} -> send_error(conn, reason)
    end
  end

  defp client_credentials(conn, params) do
    case authenticate_client(params, allow_public: false) do
      {:ok, client} ->
        scopes = parse_scopes(params["scope"], ["read"])

        case OAuth.issue_client_credentials_token(client, scopes) do
          {:ok, %{token: token, access: access}} -> send_token(conn, token, access, nil)
          _ -> send_error(conn, "server_error")
        end

      {:error, reason} ->
        send_error(conn, reason)
    end
  end

  defp refresh(conn, params) do
    with {:ok, client} <- authenticate_client(params, allow_public: false),
         {:ok, refresh_raw} <- fetch_required(params, "refresh_token"),
         {:ok, %{token: token, access: access, refresh: refresh}} <-
           OAuth.refresh_access_token(refresh_raw, client) do
      send_token(conn, token, access, refresh)
    else
      {:error, :unsupported} -> send_error(conn, "unsupported_grant_type")
      {:error, reason} -> send_error(conn, reason)
    end
  end

  ## Internals

  defp authenticate_client(params, opts) do
    allow_public = Keyword.get(opts, :allow_public, false)
    client_id = params["client_id"]
    secret = params["client_secret"]

    case OAuth.get_client(client_id) do
      nil ->
        {:error, "invalid_client"}

      %Client{} = client ->
        cond do
          OAuth.verify_client_secret(client, secret) -> {:ok, client}
          allow_public and (is_nil(secret) or secret == "") -> {:ok, client}
          true -> {:error, "invalid_client"}
        end
    end
  end

  defp fetch_required(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "invalid_request"}
    end
  end

  defp parse_scopes(nil, default), do: default
  defp parse_scopes("", default), do: default
  defp parse_scopes(s, _default) when is_binary(s), do: String.split(s, [" ", ","], trim: true)

  defp send_token(conn, token, access, refresh) do
    conn
    |> put_no_store_headers()
    |> json(render_token(token, access, refresh))
  end

  # Pixelfed (Laravel Passport) returns `refresh_token` + `expires_in`, and the
  # Pixelfed mobile app stores both unconditionally — omitting them makes the
  # app's MMKV `set(key, undefined)` throw mid-login, leaving an unusable
  # half-logged-in state. So we always include `expires_in`, and `refresh_token`
  # whenever the grant issued one.
  defp render_token(token, access, refresh) do
    %{
      "access_token" => access,
      "token_type" => "Bearer",
      "scope" => Enum.join(token.scopes, " "),
      "created_at" => DateTime.to_unix(token.inserted_at),
      "expires_in" => expires_in(token)
    }
    |> maybe_put_refresh(refresh)
  end

  defp maybe_put_refresh(body, refresh) when is_binary(refresh),
    do: Map.put(body, "refresh_token", refresh)

  defp maybe_put_refresh(body, _), do: body

  defp expires_in(%{expires_at: %DateTime{} = exp}),
    do: max(DateTime.diff(exp, DateTime.utc_now(), :second), 0)

  defp expires_in(_), do: nil

  defp send_error(conn, code) do
    code = if is_atom(code), do: Atom.to_string(code), else: code

    conn
    |> put_no_store_headers()
    |> put_status(error_status(code))
    |> json(%{"error" => code, "error_description" => describe(code)})
  end

  # RFC 6749 §5.1/§5.2 — token endpoint responses carrying credentials must
  # not be cached by intermediaries or the client.
  defp put_no_store_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end

  defp error_status("invalid_client"), do: 401
  defp error_status(_), do: 400

  defp describe("invalid_request"), do: "request was missing a required parameter"
  defp describe("invalid_client"), do: "client authentication failed"
  defp describe("invalid_grant"), do: "the credentials or code are invalid or expired"
  defp describe("unsupported_grant_type"), do: "the requested grant type is not supported"
  defp describe(_), do: "internal error"
end
