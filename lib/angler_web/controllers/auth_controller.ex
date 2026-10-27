defmodule AnglerWeb.AuthController do
  @moduledoc """
  Unversioned in-app registration endpoints.

  * POST /api/auth/app-code-verify — see plans/auth_registration/endpoints/post_invite_*; this controller mirrors Pixelfed's `verifyCode` (just checks the code).
  * POST /api/auth/onboarding — creates a user + profile + first-party OAuth token.
  """

  use AnglerWeb, :controller

  alias Angler.Accounts
  alias Angler.Auth
  alias Angler.Auth.Username
  alias Angler.OAuth

  # ---- POST /api/auth/app-code-verify -------------------------------------

  def app_code_verify(conn, %{"email" => email, "verify_code" => code})
      when is_binary(email) and is_binary(code) do
    cond do
      not valid_email?(email) ->
        json(conn, %{"status" => "error", "message" => "Invalid email"})

      not valid_code?(code) ->
        json(conn, %{"status" => "error"})

      Accounts.get_by_email(email) ->
        json(conn, %{"status" => "error", "message" => "Account already exists"})

      true ->
        case Auth.verify_code(email, code) do
          :ok -> json(conn, %{"status" => "success"})
          :locked -> locked(conn)
          :error -> json(conn, %{"status" => "error", "code" => "invalid_code"})
        end
    end
  end

  def app_code_verify(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"status" => "error", "message" => "email and verify_code are required"})
  end

  # ---- POST /api/auth/onboarding ------------------------------------------

  defp locked(conn) do
    conn
    |> put_status(:too_many_requests)
    |> json(%{
      "status" => "error",
      "code" => "locked",
      "message" => "Too many verification attempts. Please request a new code."
    })
  end

  # The new app sends its own client_id/client_secret/scope so the token is
  # issued to it (upstream 1cead5cf6); without them the first-party client is
  # used, as before.
  def onboarding(conn, params) do
    with {:ok, attrs} <- normalize_onboarding(params),
         {:ok, app} <- onboarding_client(params),
         :ok <- Username.validate(attrs.username),
         :ok <- ensure_email_unused(attrs.email),
         :ok <- ensure_username_available(attrs.username),
         :ok <- Auth.verify_code(attrs.email, attrs.verify_code),
         {:ok, %{user: user, profile: profile}} <- Accounts.register(attrs) do
      Auth.consume!(attrs.email)

      # When approval is required the account is created pending and can't hold
      # a usable token yet, so we return a pending acknowledgement instead.
      if Accounts.pending?(user) do
        conn
        |> put_status(:accepted)
        |> json(%{
          "status" => "pending",
          "message" => "Your account was created and is awaiting operator approval.",
          "user" => %{
            "pid" => Integer.to_string(profile.id),
            "username" => profile.username
          }
        })
      else
        issue_onboarding_token(conn, user, profile, app)
      end
    else
      :error ->
        json(conn, %{
          "status" => "error",
          "code" => "invalid_code",
          "message" => "Invalid verification code, please try again later."
        })

      :locked ->
        locked(conn)

      {:error, :invalid_scope} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"status" => "error", "code" => "invalid_scope", "message" => "Invalid scope."})

      {:error, :invalid_client} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{
          "status" => "error",
          "code" => "invalid_client",
          "message" => "Invalid client credentials."
        })

      {:error, :validation, missing} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"status" => "error", "message" => "Missing field: #{missing}"})

      {:error, :username_taken} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"status" => "error", "message" => "Username is taken"})

      {:error, :email_taken} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"status" => "error", "message" => "Email is already in use"})

      {:error, message} when is_binary(message) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"status" => "error", "message" => message})

      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"status" => "error", "errors" => format_changeset(cs)})
    end
  end

  ## Helpers

  @onboarding_scopes ~w(read write follow push security:read security:write)

  defp onboarding_client(%{"client_id" => id} = params) when is_binary(id) and id != "" do
    with {:ok, scopes} <- onboarding_scopes(params["scope"]),
         %OAuth.Client{} = client <- OAuth.get_client(id),
         true <- OAuth.verify_client_secret(client, params["client_secret"]) do
      {:ok, {client, scopes}}
    else
      {:error, :invalid_scope} = err -> err
      _ -> {:error, :invalid_client}
    end
  end

  defp onboarding_client(_), do: {:ok, nil}

  defp onboarding_scopes(scope) when scope in [nil, ""], do: {:ok, OAuth.default_scopes()}

  defp onboarding_scopes(scope) when is_binary(scope) do
    scopes = scope |> String.replace("+", " ") |> String.split(" ", trim: true) |> Enum.uniq()

    if scopes != [] and Enum.all?(scopes, &(&1 in @onboarding_scopes)),
      do: {:ok, scopes},
      else: {:error, :invalid_scope}
  end

  defp onboarding_scopes(_), do: {:error, :invalid_scope}

  defp issue_onboarding_token(conn, user, profile, app) do
    {client, token_opts} =
      case app do
        {client, scopes} ->
          {client, [scopes: scopes]}

        nil ->
          %{client: client} = OAuth.first_party_client!()
          {client, []}
      end

    case OAuth.issue_token(
           user,
           client,
           [ip: client_ip(conn), user_agent: List.first(get_req_header(conn, "user-agent"))] ++
             token_opts
         ) do
      {:ok, %{access: access, refresh: refresh, token: token}} ->
        json(conn, %{
          "status" => "success",
          "token_type" => "Bearer",
          "domain" => URI.parse(AnglerWeb.Endpoint.url()).host,
          "expires_in" => seconds_until(token.expires_at),
          "access_token" => access,
          "refresh_token" => refresh,
          "client_id" => Integer.to_string(client.id),
          # Pixelfed includes the client secret here; for our hashed-secret design
          # the secret is generated once at first_party_client! creation and is
          # not retrievable thereafter — we return null and document the change.
          "client_secret" => nil,
          "scope" => token.scopes,
          "user" => %{
            "pid" => Integer.to_string(profile.id),
            "username" => profile.username
          },
          "account" => render_account(profile)
        })

      _ when app != nil ->
        json(conn, %{
          "status" => "error",
          "code" => "account_created_token_failed",
          "message" =>
            "Your account was created but we could not sign you in automatically. " <>
              "Please sign in with your email and password."
        })

      _ ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{"status" => "error", "message" => "Could not issue a token."})
    end
  end

  defp ensure_email_unused(email) do
    if Accounts.get_by_email(email), do: {:error, :email_taken}, else: :ok
  end

  defp ensure_username_available(username) do
    if Accounts.username_available?(username), do: :ok, else: {:error, :username_taken}
  end

  defp normalize_onboarding(params) do
    required = ~w(email verify_code username password)
    missing = Enum.find(required, &blank?(params[&1]))

    if missing do
      {:error, :validation, missing}
    else
      {:ok,
       %{
         email: params["email"] |> String.downcase(),
         verify_code: params["verify_code"],
         username: params["username"],
         name: Map.get(params, "name"),
         password: params["password"]
       }}
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp valid_email?(email) when is_binary(email),
    do: Regex.match?(~r/^[^\s@]+@[^\s@]+$/, email)

  defp valid_code?(code) when is_binary(code), do: Regex.match?(~r/^\d{6}$/, code)

  defp seconds_until(nil), do: nil

  defp seconds_until(at) do
    DateTime.diff(at, DateTime.utc_now(), :second)
  end

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [first | _] -> first |> String.split(",") |> List.first() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp render_account(profile) do
    %{
      "id" => Integer.to_string(profile.id),
      "username" => profile.username,
      "acct" => profile.username,
      "display_name" => profile.name || "",
      "locked" => profile.is_private,
      "bot" => false,
      "discoverable" => profile.discoverable,
      "group" => false,
      "created_at" => profile.inserted_at && DateTime.to_iso8601(profile.inserted_at),
      "note" => profile.bio || "",
      "url" => Angler.Profiles.url(profile),
      "avatar" => "",
      "avatar_static" => "",
      "header" => "",
      "header_static" => "",
      "followers_count" => profile.followers_count,
      "following_count" => profile.following_count,
      "statuses_count" => profile.statuses_count,
      "last_status_at" => nil,
      "emojis" => [],
      "moved" => nil,
      "fields" => []
    }
  end

  defp format_changeset(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
