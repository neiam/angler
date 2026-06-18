defmodule Angler.OAuth do
  @moduledoc """
  OAuth 2.0 token + client lifecycle.

  Tokens are opaque (random 64-byte url-safe). Only the SHA-256 hash is
  persisted; the raw value is returned to the caller exactly once at issue time.
  """

  import Ecto.Query, warn: false
  alias Angler.Accounts
  alias Angler.Accounts.User
  alias Angler.OAuth.{AuthorizationCode, Client, Token}
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

  @doc """
  Register a third-party OAuth client (POST /api/v1/apps).

  Returns `{:ok, %{client: client, secret: raw}}` — `secret` is the only
  place the plaintext exists.
  """
  @spec register_client(map()) ::
          {:ok, %{client: Client.t(), secret: String.t()}}
          | {:error, Ecto.Changeset.t()}
  def register_client(attrs) when is_map(attrs) do
    secret = generate_token_string()
    redirect_uris = parse_redirect_uris(attrs["redirect_uris"])
    scopes = parse_scopes(attrs["scopes"])

    %Client{}
    |> Client.changeset(%{
      name: html_escape(attrs["client_name"]),
      website: attrs["website"],
      redirect_uris: redirect_uris,
      scopes: scopes,
      secret_hash: hash(secret),
      first_party: false
    })
    |> validate_app()
    |> Repo.insert()
    |> case do
      {:ok, client} -> {:ok, %{client: client, secret: secret}}
      {:error, cs} -> {:error, cs}
    end
  end

  defp parse_redirect_uris(nil), do: []
  defp parse_redirect_uris([]), do: []

  defp parse_redirect_uris(s) when is_binary(s) do
    s
    |> String.split(["\n", ","])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_redirect_uris(list) when is_list(list) do
    list |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_scopes(nil), do: ["read"]
  defp parse_scopes(""), do: ["read"]

  defp parse_scopes(s) when is_binary(s) do
    s |> String.split([" ", ","], trim: true)
  end

  defp parse_scopes(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp parse_scopes(_), do: ["read"]

  defp validate_app(changeset) do
    import Ecto.Changeset

    name = get_field(changeset, :name) || ""
    uris = get_field(changeset, :redirect_uris) || []

    changeset
    |> validate_change(:name, fn _, _ ->
      cond do
        name == "" -> [name: "can't be blank"]
        String.length(name) > 60 -> [name: "is too long (max 60 chars)"]
        true -> []
      end
    end)
    |> then(fn cs ->
      cond do
        uris == [] ->
          add_error(cs, :redirect_uris, "is required")

        Enum.any?(uris, fn u -> not valid_redirect_uri?(u) end) ->
          add_error(cs, :redirect_uris, "must be a valid URI")

        true ->
          cs
      end
    end)
  end

  defp valid_redirect_uri?("urn:ietf:wg:oauth:2.0:oob"), do: true

  defp valid_redirect_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: s, host: h} when is_binary(s) and is_binary(h) -> true
      _ -> false
    end
  end

  defp valid_redirect_uri?(_), do: false

  ## Authorization codes (the `authorization_code` grant)

  @code_ttl_seconds 10 * 60

  @doc """
  Look up a client by raw client_id (string or integer).
  """
  @spec get_client(String.t() | integer()) :: Client.t() | nil
  def get_client(id) when is_integer(id), do: Repo.get(Client, id)

  def get_client(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> Repo.get(Client, n)
      _ -> nil
    end
  end

  def get_client(_), do: nil

  @doc """
  Verify a `(client_id, client_secret)` pair. `secret` may be `nil` for
  public PKCE clients (we don't enforce the secret then — RFC 7636).
  """
  @spec verify_client_secret(Client.t() | nil, String.t() | nil) :: boolean()
  def verify_client_secret(nil, _), do: false

  def verify_client_secret(%Client{secret_hash: stored}, raw) when is_binary(raw) do
    Plug.Crypto.secure_compare(stored, hash(raw))
  end

  def verify_client_secret(_, _), do: false

  @doc """
  Issue a fresh authorization code for `(user, client)`. Returns the raw code
  (only place the plaintext exists) plus the persisted row.
  """
  @spec create_authorization_code(User.t(), Client.t(), [String.t()], keyword()) ::
          {:ok, %{code: String.t(), row: AuthorizationCode.t()}}
          | {:error, Ecto.Changeset.t()}
  def create_authorization_code(%User{} = user, %Client{} = client, scopes, opts) do
    raw = generate_token_string()
    redirect_uri = Keyword.fetch!(opts, :redirect_uri)
    challenge = Keyword.get(opts, :code_challenge)
    method = Keyword.get(opts, :code_challenge_method)

    %{
      code_hash: hash(raw),
      client_id: client.id,
      user_id: user.id,
      scopes: scopes,
      redirect_uri: redirect_uri,
      code_challenge: challenge,
      code_challenge_method: method,
      expires_at: DateTime.add(DateTime.utc_now(), @code_ttl_seconds, :second)
    }
    |> AuthorizationCode.changeset()
    |> Repo.insert()
    |> case do
      {:ok, row} -> {:ok, %{code: raw, row: row}}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc """
  Exchange an authorization code for an access token.

  Validates: code exists, not redeemed, not expired, client matches,
  redirect_uri matches, PKCE verifier matches (when challenge was set).
  Atomically marks the code redeemed before issuing the token.
  """
  @spec redeem_authorization_code(String.t(), Client.t(), String.t(), String.t() | nil) ::
          {:ok, %{token: Token.t(), access: String.t(), refresh: String.t() | nil}}
          | {:error, atom()}
  def redeem_authorization_code(raw_code, %Client{} = client, redirect_uri, code_verifier) do
    Repo.transaction(fn ->
      case lock_code(raw_code) do
        nil ->
          Repo.rollback(:invalid_grant)

        %AuthorizationCode{redeemed_at: %DateTime{}} ->
          Repo.rollback(:invalid_grant)

        %AuthorizationCode{client_id: cid} when cid != client.id ->
          Repo.rollback(:invalid_grant)

        %AuthorizationCode{} = row ->
          cond do
            DateTime.compare(DateTime.utc_now(), row.expires_at) == :gt ->
              Repo.rollback(:invalid_grant)

            row.redirect_uri != redirect_uri ->
              Repo.rollback(:invalid_grant)

            not pkce_ok?(row, code_verifier) ->
              Repo.rollback(:invalid_grant)

            true ->
              {:ok, _} =
                row
                |> Ecto.Changeset.change(redeemed_at: DateTime.utc_now())
                |> Repo.update()

              user = Repo.get!(User, row.user_id)

              case issue_token(user, client, scopes: row.scopes) do
                {:ok, issued} -> issued
                {:error, _} -> Repo.rollback(:server_error)
              end
          end
      end
    end)
  end

  defp lock_code(raw_code) do
    Repo.one(
      from c in AuthorizationCode, where: c.code_hash == ^hash(raw_code), lock: "FOR UPDATE"
    )
  end

  defp pkce_ok?(%AuthorizationCode{code_challenge: nil}, _verifier), do: true
  defp pkce_ok?(_, nil), do: false

  defp pkce_ok?(
         %AuthorizationCode{code_challenge: challenge, code_challenge_method: method},
         verifier
       ) do
    case method || "S256" do
      "S256" ->
        digest = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
        Plug.Crypto.secure_compare(digest, challenge)

      "plain" ->
        Plug.Crypto.secure_compare(verifier, challenge)

      _ ->
        false
    end
  end

  ## password grant

  @doc """
  Resource-owner password grant. Verifies credentials and issues a token.
  """
  @spec issue_password_token(String.t(), String.t(), Client.t(), [String.t()], keyword()) ::
          {:ok, %{token: Token.t(), access: String.t(), refresh: String.t() | nil}}
          | {:error, :invalid_grant}
  def issue_password_token(username_or_email, password, %Client{} = client, scopes, opts \\ []) do
    user = lookup_user(username_or_email)

    cond do
      is_nil(user) ->
        # Run a dummy verify to keep timing constant — Argon2.no_user_verify
        # is invoked inside valid_password?/2's nil branch.
        _ = User.valid_password?(nil, password)
        {:error, :invalid_grant}

      not User.valid_password?(user, password) ->
        {:error, :invalid_grant}

      true ->
        case verify_second_factor(user, opts[:otp]) do
          :ok -> issue_token(user, client, Keyword.put(opts, :scopes, scopes))
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # When the account has a second factor, the password grant additionally
  # requires a TOTP or recovery code passed as `otp`. WebAuthn can't run over a
  # non-interactive token POST, but enrolling any factor always mints recovery
  # codes, so a key-only user can still pass one here. Returns `:mfa_required`
  # when the code is absent so the client can prompt for it.
  defp verify_second_factor(user, otp) do
    if Angler.Accounts.TwoFactor.any_factor?(user) do
      cond do
        otp in [nil, ""] -> {:error, :mfa_required}
        Angler.Accounts.TwoFactor.verify_code(user, otp) == :ok -> :ok
        Angler.Accounts.TwoFactor.verify_recovery_code(user, otp) == :ok -> :ok
        true -> {:error, :invalid_grant}
      end
    else
      :ok
    end
  end

  defp lookup_user(handle) do
    case String.contains?(handle || "", "@") do
      true ->
        Accounts.get_by_email(handle)

      false ->
        # Resolve by local username via the profile.
        case Angler.Profiles.get_local_by_username(handle) do
          %{id: pid} -> Repo.one(from u in User, where: u.profile_id == ^pid and is_nil(u.status))
          _ -> nil
        end
    end
  end

  ## client_credentials grant

  @doc """
  Issue a token bound to the client only (no `user_id`). Mastodon ecosystem
  uses this for unauthenticated reads of public timelines/statuses.
  """
  @spec issue_client_credentials_token(Client.t(), [String.t()]) ::
          {:ok, %{token: Token.t(), access: String.t()}}
          | {:error, term()}
  def issue_client_credentials_token(%Client{} = client, scopes) do
    access = generate_token_string()

    %Token{}
    |> Token.changeset(%{
      token_hash: hash(access),
      client_id: client.id,
      user_id: nil,
      profile_id: nil,
      scopes: scopes,
      expires_at: DateTime.add(DateTime.utc_now(), @access_ttl_days * 86_400, :second)
    })
    |> Repo.insert()
    |> case do
      {:ok, token} -> {:ok, %{token: token, access: access}}
      err -> err
    end
  end

  ## refresh_token grant (off by default)

  @doc """
  Whether refresh tokens are enabled.

  Off by default; `config :angler, oauth_refresh_tokens: true` to enable.
  """
  def refresh_tokens_enabled? do
    Application.get_env(:angler, :oauth_refresh_tokens, false) == true
  end

  @doc """
  Exchange a refresh token for a new access token. Revokes the old token.
  """
  @spec refresh_access_token(String.t(), Client.t()) ::
          {:ok, %{token: Token.t(), access: String.t(), refresh: String.t()}}
          | {:error, :invalid_grant | :unsupported}
  def refresh_access_token(raw, client) when is_binary(raw) do
    if refresh_tokens_enabled?() do
      do_refresh(raw, client)
    else
      {:error, :unsupported}
    end
  end

  defp do_refresh(raw, %Client{} = client) do
    case Repo.get_by(Token, refresh_hash: hash(raw)) do
      %Token{client_id: cid, revoked_at: nil, refresh_expires_at: rexp} = old
      when cid == client.id ->
        if rexp && DateTime.compare(DateTime.utc_now(), rexp) == :gt do
          {:error, :invalid_grant}
        else
          revoke(old)
          user = old.user_id && Repo.get(User, old.user_id)

          if user,
            do: issue_token(user, client, scopes: old.scopes),
            else: {:error, :invalid_grant}
        end

      _ ->
        {:error, :invalid_grant}
    end
  end

  ## Revoke

  @doc """
  Revoke by raw access token. Idempotent. Per RFC 7009, the response is
  always 200 — but we still verify the token belongs to the client to avoid
  cross-client revocation.
  """
  @spec revoke_raw_token(String.t(), Client.t() | nil) :: :ok
  def revoke_raw_token(raw, client) when is_binary(raw) do
    case Repo.get_by(Token, token_hash: hash(raw)) do
      %Token{client_id: cid} = token when client == nil or cid == client.id ->
        revoke(token)
        :ok

      _ ->
        :ok
    end
  end

  defp html_escape(nil), do: nil

  defp html_escape(s) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
