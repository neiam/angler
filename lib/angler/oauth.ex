defmodule Angler.OAuth do
  @moduledoc """
  OAuth 2.0 token + client lifecycle.

  Tokens are opaque (random 64-byte url-safe). Only the SHA-256 hash is
  persisted; the raw value is returned to the caller exactly once at issue time.
  """

  import Ecto.Query, warn: false
  alias Angler.OAuth.{Client, Token}
  alias Angler.Repo

  @default_scopes ~w(read write follow push)
  @access_ttl_days 365
  @refresh_ttl_days 400

  @first_party_client_name "Pixelfed"

  @doc """
  Return the singleton first-party client used by the in-app onboarding flow.

  Inserted on first call. Mirrors Pixelfed's "Pixelfed App" personal access
  token client.
  """
  @spec first_party_client!() :: %{client: Client.t(), secret: String.t()}
  def first_party_client! do
    case Repo.get_by(Client, name: @first_party_client_name, first_party: true) do
      nil -> create_first_party!()
      client -> %{client: client, secret: nil}
    end
  end

  defp create_first_party! do
    secret = generate_token_string()

    {:ok, client} =
      %Client{}
      |> Client.changeset(%{
        name: @first_party_client_name,
        secret_hash: hash(secret),
        redirect_uris: ["urn:ietf:wg:oauth:2.0:oob"],
        scopes: @default_scopes,
        first_party: true
      })
      |> Repo.insert()

    %{client: client, secret: secret}
  end

  @doc """
  Issue a fresh access (+refresh) token for a `(user, client)` pair.

  Returns the raw access token string and a `Token` row. The raw value is the
  only place the bearer plaintext exists — store it client-side immediately.
  """
  @spec issue_token(Angler.Accounts.User.t(), Client.t(), keyword()) ::
          {:ok, %{token: Token.t(), access: String.t(), refresh: String.t()}}
          | {:error, Ecto.Changeset.t()}
  def issue_token(user, %Client{} = client, opts \\ []) do
    access = generate_token_string()
    refresh = generate_token_string()
    scopes = Keyword.get(opts, :scopes, client.scopes)

    %Token{}
    |> Token.changeset(%{
      token_hash: hash(access),
      refresh_hash: hash(refresh),
      client_id: client.id,
      user_id: user.id,
      profile_id: user.profile_id,
      scopes: scopes,
      expires_at: DateTime.add(DateTime.utc_now(), @access_ttl_days * 86_400, :second),
      refresh_expires_at: DateTime.add(DateTime.utc_now(), @refresh_ttl_days * 86_400, :second),
      ip: opts[:ip],
      user_agent: opts[:user_agent]
    })
    |> Repo.insert()
    |> case do
      {:ok, token} -> {:ok, %{token: token, access: access, refresh: refresh}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Look up a token by its raw access value. Used by the bearer-auth plug."
  @spec lookup_by_access(String.t()) :: {:ok, Token.t()} | :error
  def lookup_by_access(raw) when is_binary(raw) do
    case Repo.get_by(Token, token_hash: hash(raw)) do
      %Token{revoked_at: nil} = t ->
        if expired?(t.expires_at), do: :error, else: {:ok, t}

      _ ->
        :error
    end
  end

  # Time between writes of `last_used_at`. Tighter than this and we burn a write
  # per request; looser and admin "last seen" displays lag too much.
  @touch_debounce_seconds 300

  @doc """
  Bump `last_used_at` on a token, but at most every #{@touch_debounce_seconds}
  seconds — avoids a DB write on every authenticated request.

  Safe to call inline from the plug. Returns the (possibly unchanged) token.
  """
  @spec touch_used(Token.t()) :: Token.t()
  def touch_used(%Token{last_used_at: last_used_at} = token) do
    now = DateTime.utc_now()

    if stale?(last_used_at, now, @touch_debounce_seconds) do
      {1, _} =
        from(t in Token, where: t.id == ^token.id)
        |> Repo.update_all(set: [last_used_at: now])

      %{token | last_used_at: now}
    else
      token
    end
  end

  defp stale?(nil, _now, _window), do: true
  defp stale?(at, now, window), do: DateTime.diff(now, at, :second) >= window

  @doc """
  Revoke a token. Idempotent. Returns the (possibly already-revoked) token.
  """
  @spec revoke(Token.t()) :: Token.t()
  def revoke(%Token{revoked_at: nil} = token) do
    now = DateTime.utc_now()

    {1, _} =
      from(t in Token, where: t.id == ^token.id)
      |> Repo.update_all(set: [revoked_at: now])

    %{token | revoked_at: now}
  end

  def revoke(%Token{} = token), do: token

  defp expired?(nil), do: false
  defp expired?(at), do: DateTime.compare(DateTime.utc_now(), at) == :gt

  defp generate_token_string do
    :crypto.strong_rand_bytes(48) |> Base.url_encode64(padding: false)
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw)

  @doc "Default scopes issued by the in-app onboarding flow."
  def default_scopes, do: @default_scopes
end
