defmodule AnglerWeb.Plugs.BearerAuth do
  @moduledoc """
  OAuth 2.0 bearer-token authentication.

  ## Usage

      # Required auth (any valid token):
      plug AnglerWeb.Plugs.BearerAuth

      # Required auth + scope check (all scopes must be satisfied):
      plug AnglerWeb.Plugs.BearerAuth, scopes: ["read"]
      plug AnglerWeb.Plugs.BearerAuth, scopes: ["write:statuses"]

      # Optional auth — assigns current_scope if a valid bearer is present,
      # otherwise leaves it unset and continues anonymously:
      plug AnglerWeb.Plugs.BearerAuth, optional: true

  On success, `conn.assigns.current_scope` is set to an `Angler.Auth.Scope`.
  On failure (in required mode), the plug halts the conn and writes a
  Mastodon-style JSON error.

  ## Scope semantics

  Mastodon scopes are hierarchical: a token granted `read` covers
  `read:accounts`, `read:statuses`, etc. The plug uses `Angler.Auth.Scope.has_scope?/2`
  for the check.

  When multiple scopes are required, **all** must be satisfied (AND).

  ## Error envelope

  | Status | When                                              | Body                                                |
  | ------ | ------------------------------------------------- | --------------------------------------------------- |
  | 401    | Missing/malformed bearer, unknown/expired/revoked | `{"error": "The access token is invalid"}`         |
  | 403    | Token valid but scopes insufficient               | `{"error": "This action is outside the authorized scopes"}` |
  """

  @behaviour Plug

  import Plug.Conn

  alias Angler.Accounts
  alias Angler.Auth.Scope
  alias Angler.OAuth
  alias Angler.Profiles

  @missing_token_msg "The access token is invalid"
  @insufficient_scope_msg "This action is outside the authorized scopes"

  @type opts :: %{required: boolean(), scopes: [String.t()]}

  @impl Plug
  def init(opts) do
    %{
      required: not Keyword.get(opts, :optional, false),
      scopes: Keyword.get(opts, :scopes, [])
    }
  end

  @impl Plug
  def call(conn, %{required: required, scopes: required_scopes}) do
    case extract_bearer(conn) do
      {:ok, raw} ->
        case authenticate(raw) do
          {:ok, scope} ->
            conn
            |> assign(:current_scope, scope)
            |> enforce_scopes(required_scopes)

          :error when required ->
            unauthorized(conn)

          :error ->
            conn
        end

      :error when required ->
        unauthorized(conn)

      :error ->
        conn
    end
  end

  @doc "Convenience for controllers."
  @spec current_scope(Plug.Conn.t()) :: Scope.t() | nil
  def current_scope(conn), do: conn.assigns[:current_scope]

  ## Internals

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw] when byte_size(raw) > 0 -> {:ok, raw}
      ["bearer " <> raw] when byte_size(raw) > 0 -> {:ok, raw}
      _ -> :error
    end
  end

  defp authenticate(raw) do
    with {:ok, token} <- OAuth.lookup_by_access(raw),
         %Accounts.User{status: nil} = user <- Accounts.get_user(token.user_id),
         %Profiles.Profile{status: nil} = profile <- Profiles.get_profile(token.profile_id) do
      token = OAuth.touch_used(token)

      {:ok,
       %Scope{
         user: user,
         profile: profile,
         token: token,
         scopes: token.scopes
       }}
    else
      _ -> :error
    end
  end

  defp enforce_scopes(conn, []), do: conn

  defp enforce_scopes(conn, required) do
    scope = conn.assigns.current_scope

    if Enum.all?(required, &Scope.has_scope?(scope, &1)) do
      conn
    else
      forbidden(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode_to_iodata!(%{"error" => @missing_token_msg}))
    |> halt()
  end

  defp forbidden(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode_to_iodata!(%{"error" => @insufficient_scope_msg}))
    |> halt()
  end
end
