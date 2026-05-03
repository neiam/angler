defmodule Angler.OAuthGrantsTest do
  use Angler.DataCase, async: false

  alias Angler.Accounts
  alias Angler.OAuth
  alias Angler.OAuth.{AuthorizationCode, Client, Token}

  defp register!(opts \\ []) do
    {:ok, %{user: user, profile: profile}} =
      Accounts.register(%{
        username: opts[:username] || "alice",
        email: opts[:email] || "alice@example.com",
        password: opts[:password] || "verysecret123"
      })

    {user, profile}
  end

  defp register_client!(name \\ "MyClient") do
    {:ok, %{client: client, secret: secret}} =
      OAuth.register_client(%{
        "client_name" => name,
        "redirect_uris" => "https://app.example/cb",
        "scopes" => "read write follow"
      })

    {client, secret}
  end

  describe "register_client/1" do
    test "stored secret_hash is the SHA-256 of the raw secret" do
      {client, secret} = register_client!()
      assert byte_size(client.secret_hash) == 32
      assert OAuth.verify_client_secret(client, secret)
      refute OAuth.verify_client_secret(client, "wrong")
    end
  end

  describe "create_authorization_code/4 + redeem_authorization_code/4" do
    setup do
      {user, _} = register!()
      {client, secret} = register_client!()
      %{user: user, client: client, secret: secret}
    end

    test "happy path: redeem yields a token", %{user: user, client: client} do
      {:ok, %{code: code}} =
        OAuth.create_authorization_code(user, client, ["read", "write"],
          redirect_uri: "https://app.example/cb"
        )

      {:ok, %{token: token, access: access}} =
        OAuth.redeem_authorization_code(code, client, "https://app.example/cb", nil)

      assert is_binary(access)
      assert token.user_id == user.id
      assert token.scopes == ["read", "write"]

      # Code is now redeemed.
      [row] = Repo.all(AuthorizationCode)
      assert row.redeemed_at
    end

    test "second redemption of the same code fails", %{user: user, client: client} do
      {:ok, %{code: code}} =
        OAuth.create_authorization_code(user, client, ["read"],
          redirect_uri: "https://app.example/cb"
        )

      {:ok, _} = OAuth.redeem_authorization_code(code, client, "https://app.example/cb", nil)

      assert {:error, :invalid_grant} =
               OAuth.redeem_authorization_code(code, client, "https://app.example/cb", nil)
    end

    test "wrong redirect_uri rejects", %{user: user, client: client} do
      {:ok, %{code: code}} =
        OAuth.create_authorization_code(user, client, ["read"],
          redirect_uri: "https://app.example/cb"
        )

      assert {:error, :invalid_grant} =
               OAuth.redeem_authorization_code(code, client, "https://attacker.example/cb", nil)
    end

    test "wrong client rejects", %{user: user, client: client} do
      {other, _} = register_client!("Other")

      {:ok, %{code: code}} =
        OAuth.create_authorization_code(user, client, ["read"],
          redirect_uri: "https://app.example/cb"
        )

      assert {:error, :invalid_grant} =
               OAuth.redeem_authorization_code(code, other, "https://app.example/cb", nil)
    end

    test "expired code rejects", %{user: user, client: client} do
      {:ok, %{code: code, row: row}} =
        OAuth.create_authorization_code(user, client, ["read"],
          redirect_uri: "https://app.example/cb"
        )

      # Force expire
      row
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

      assert {:error, :invalid_grant} =
               OAuth.redeem_authorization_code(code, client, "https://app.example/cb", nil)
    end

    test "PKCE S256 verifier matches challenge", %{user: user, client: client} do
      verifier = "the-quick-brown-fox-jumps-over-the-lazy-dog-1234567890abcd"
      challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

      {:ok, %{code: code}} =
        OAuth.create_authorization_code(user, client, ["read"],
          redirect_uri: "https://app.example/cb",
          code_challenge: challenge,
          code_challenge_method: "S256"
        )

      assert {:ok, _} =
               OAuth.redeem_authorization_code(
                 code,
                 client,
                 "https://app.example/cb",
                 verifier
               )
    end

    test "PKCE S256 wrong verifier rejects", %{user: user, client: client} do
      challenge = :crypto.hash(:sha256, "x") |> Base.url_encode64(padding: false)

      {:ok, %{code: code}} =
        OAuth.create_authorization_code(user, client, ["read"],
          redirect_uri: "https://app.example/cb",
          code_challenge: challenge,
          code_challenge_method: "S256"
        )

      assert {:error, :invalid_grant} =
               OAuth.redeem_authorization_code(
                 code,
                 client,
                 "https://app.example/cb",
                 "wrong"
               )
    end

    test "PKCE S256 missing verifier rejects", %{user: user, client: client} do
      challenge = :crypto.hash(:sha256, "x") |> Base.url_encode64(padding: false)

      {:ok, %{code: code}} =
        OAuth.create_authorization_code(user, client, ["read"],
          redirect_uri: "https://app.example/cb",
          code_challenge: challenge,
          code_challenge_method: "S256"
        )

      assert {:error, :invalid_grant} =
               OAuth.redeem_authorization_code(code, client, "https://app.example/cb", nil)
    end
  end

  describe "issue_password_token/5" do
    test "valid creds → token" do
      {_, _} = register!(username: "bob", email: "bob@example.com", password: "passwordOK1")
      {client, _} = register_client!()

      assert {:ok, %{token: %Token{user_id: uid}}} =
               OAuth.issue_password_token("bob@example.com", "passwordOK1", client, ["read"])

      assert is_integer(uid)
    end

    test "wrong password → invalid_grant" do
      {_, _} = register!(username: "bob", email: "bob@example.com", password: "passwordOK1")
      {client, _} = register_client!()

      assert {:error, :invalid_grant} =
               OAuth.issue_password_token("bob@example.com", "wrong", client, ["read"])
    end

    test "missing user → invalid_grant" do
      {client, _} = register_client!()

      assert {:error, :invalid_grant} =
               OAuth.issue_password_token("nobody@example.com", "x", client, ["read"])
    end

    test "username (not email) also works" do
      {_, _} = register!(username: "carol", email: "carol@example.com", password: "passwordOK1")
      {client, _} = register_client!()

      assert {:ok, _} = OAuth.issue_password_token("carol", "passwordOK1", client, ["read"])
    end
  end

  describe "issue_client_credentials_token/2" do
    test "issues a token with user_id = nil" do
      {client, _} = register_client!()

      assert {:ok, %{token: %Token{user_id: nil} = t}} =
               OAuth.issue_client_credentials_token(client, ["read"])

      assert t.client_id == client.id
    end
  end

  describe "refresh tokens" do
    test "disabled by default" do
      {client, _} = register_client!()
      assert {:error, :unsupported} = OAuth.refresh_access_token("anything", client)
    end

    test "when enabled, exchanges and revokes the old token" do
      Application.put_env(:angler, :oauth_refresh_tokens, true)
      on_exit(fn -> Application.put_env(:angler, :oauth_refresh_tokens, false) end)

      {user, _} = register!()
      {client, _} = register_client!()
      {:ok, %{token: old, refresh: refresh}} = OAuth.issue_token(user, client, scopes: ["read"])

      assert {:ok, %{token: new, access: _}} = OAuth.refresh_access_token(refresh, client)
      assert new.id != old.id
      reloaded = Repo.get!(Token, old.id)
      assert reloaded.revoked_at
    end
  end

  describe "revoke_raw_token/2" do
    test "revokes a token belonging to the client" do
      {user, _} = register!()
      {client, _} = register_client!()
      {:ok, %{access: raw}} = OAuth.issue_token(user, client)

      assert :ok = OAuth.revoke_raw_token(raw, client)
      assert :error = OAuth.lookup_by_access(raw)
    end

    test "ignores tokens belonging to a different client" do
      {user, _} = register!()
      {a, _} = register_client!()
      {b, _} = register_client!("Other")
      {:ok, %{access: raw}} = OAuth.issue_token(user, a)

      assert :ok = OAuth.revoke_raw_token(raw, b)
      # Still valid for client a.
      assert {:ok, _} = OAuth.lookup_by_access(raw)
    end

    test "always 200 / :ok for unknown tokens" do
      {client, _} = register_client!()
      assert :ok = OAuth.revoke_raw_token("never-was-a-token", client)
    end
  end

  describe "verify_client_secret/2" do
    test "constant-time compare against the stored hash" do
      {client, secret} = register_client!()
      assert OAuth.verify_client_secret(client, secret)
      refute OAuth.verify_client_secret(client, secret <> "x")
      refute OAuth.verify_client_secret(client, nil)
      refute OAuth.verify_client_secret(nil, secret)
    end
  end

  describe "get_client/1" do
    test "by integer id and stringified id" do
      {client, _} = register_client!()
      assert %Client{} = OAuth.get_client(client.id)
      assert %Client{} = OAuth.get_client(Integer.to_string(client.id))
      assert nil == OAuth.get_client("nope")
      assert nil == OAuth.get_client(nil)
    end
  end
end
