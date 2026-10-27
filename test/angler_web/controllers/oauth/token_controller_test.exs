defmodule AnglerWeb.OAuth.TokenControllerTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.OAuth

  defp register!(opts \\ []) do
    {:ok, %{user: user}} =
      Accounts.register(%{
        username: opts[:username] || "alice",
        email: opts[:email] || "alice@example.com",
        password: opts[:password] || "verysecret123"
      })

    user
  end

  defp register_client! do
    {:ok, %{client: client, secret: secret}} =
      OAuth.register_client(%{
        "client_name" => "TC",
        "redirect_uris" => "https://app.example/cb",
        "scopes" => "read write follow"
      })

    {client, secret}
  end

  describe "POST /oauth/token grant_type=password" do
    setup do
      register!()
      {client, secret} = register_client!()
      %{client_id: Integer.to_string(client.id), client_secret: secret}
    end

    test "200 with access_token", %{conn: conn} = ctx do
      resp =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "password",
          "client_id" => ctx.client_id,
          "client_secret" => ctx.client_secret,
          "username" => "alice@example.com",
          "password" => "verysecret123",
          "scope" => "read write"
        })

      body = json_response(resp, 200)
      assert body["token_type"] == "Bearer"
      assert is_binary(body["access_token"])
      assert body["scope"] == "read write"

      # Pixelfed/Passport shape — the mobile app stores these unconditionally
      # (a missing/undefined value throws in react-native-mmkv mid-login), so
      # they must be present and correctly typed.
      assert is_binary(body["refresh_token"])
      assert is_integer(body["expires_in"]) and body["expires_in"] > 0
      assert is_integer(body["created_at"])

      # RFC 6749 §5.1 — token responses must not be cached.
      assert get_resp_header(resp, "cache-control") == ["no-store"]
      assert get_resp_header(resp, "pragma") == ["no-cache"]
    end

    test "400 invalid_grant on bad password", %{conn: conn} = ctx do
      resp =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "password",
          "client_id" => ctx.client_id,
          "client_secret" => ctx.client_secret,
          "username" => "alice@example.com",
          "password" => "wrong"
        })

      assert json_response(resp, 400)["error"] == "invalid_grant"
    end

    test "429 after repeated failures, until the window passes", %{conn: conn} = ctx do
      key = AnglerWeb.LoginThrottle.key({127, 0, 0, 1}, "alice@example.com")
      on_exit(fn -> Angler.RateLimit.reset(key) end)

      attempt = fn password ->
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "password",
          "client_id" => ctx.client_id,
          "client_secret" => ctx.client_secret,
          "username" => "alice@example.com",
          "password" => password
        })
      end

      for _ <- 1..5,
          do: assert(json_response(attempt.("wrong"), 400)["error"] == "invalid_grant")

      # Even the right password is refused while throttled.
      assert json_response(attempt.("verysecret123"), 429)["error"] == "too_many_attempts"

      Angler.RateLimit.reset(key)
      assert json_response(attempt.("verysecret123"), 200)
    end

    test "the throttle keys on the forwarded client, not the proxy", %{conn: conn} = ctx do
      # The test peer, 127.0.0.1, is a trusted proxy by default.
      attacker = {203, 0, 113, 7}
      victim = {198, 51, 100, 9}

      for ip <- [attacker, victim, {127, 0, 0, 1}] do
        key = AnglerWeb.LoginThrottle.key(ip, "alice@example.com")
        on_exit(fn -> Angler.RateLimit.reset(key) end)
      end

      attempt = fn forwarded_for, password ->
        conn
        |> put_req_header("x-forwarded-for", forwarded_for)
        |> post(~p"/oauth/token", %{
          "grant_type" => "password",
          "client_id" => ctx.client_id,
          "client_secret" => ctx.client_secret,
          "username" => "alice@example.com",
          "password" => password
        })
      end

      for _ <- 1..5,
          do: assert(json_response(attempt.("203.0.113.7", "wrong"), 400))

      assert json_response(attempt.("203.0.113.7", "verysecret123"), 429)

      # Another client, through the same proxy, still has its own budget.
      assert json_response(attempt.("198.51.100.9, 10.0.0.5", "verysecret123"), 200)
    end

    test "401 invalid_client on wrong secret", %{conn: conn} = ctx do
      resp =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "password",
          "client_id" => ctx.client_id,
          "client_secret" => "nope",
          "username" => "alice@example.com",
          "password" => "verysecret123"
        })

      assert json_response(resp, 401)["error"] == "invalid_client"
    end

    test "400 invalid_request when password missing", %{conn: conn} = ctx do
      resp =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "password",
          "client_id" => ctx.client_id,
          "client_secret" => ctx.client_secret,
          "username" => "alice@example.com"
        })

      assert json_response(resp, 400)["error"] == "invalid_request"
    end

    test "401 mfa_required when 2FA is on and no otp", %{conn: conn} = ctx do
      enable_totp!()

      resp =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "password",
          "client_id" => ctx.client_id,
          "client_secret" => ctx.client_secret,
          "username" => "alice@example.com",
          "password" => "verysecret123"
        })

      assert json_response(resp, 401)["error"] == "mfa_required"
    end

    test "200 when a valid otp accompanies the password", %{conn: conn} = ctx do
      secret = enable_totp!()

      resp =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "password",
          "client_id" => ctx.client_id,
          "client_secret" => ctx.client_secret,
          "username" => "alice@example.com",
          "password" => "verysecret123",
          "otp" => NimbleTOTP.verification_code(secret)
        })

      assert is_binary(json_response(resp, 200)["access_token"])
    end
  end

  # Turn on TOTP for the seeded alice; returns the raw secret.
  defp enable_totp! do
    user = Accounts.get_by_email("alice@example.com")
    secret = Angler.Accounts.TwoFactor.new_secret()

    {:ok, _} =
      Angler.Accounts.TwoFactor.enable(user, secret, NimbleTOTP.verification_code(secret))

    secret
  end

  describe "POST /oauth/token grant_type=client_credentials" do
    test "200 with access_token (no user)", %{conn: conn} do
      {client, secret} = register_client!()

      resp =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "client_credentials",
          "client_id" => Integer.to_string(client.id),
          "client_secret" => secret
        })

      body = json_response(resp, 200)
      assert is_binary(body["access_token"])

      {:ok, t} = OAuth.lookup_by_access(body["access_token"])
      assert t.user_id == nil
    end
  end

  describe "POST /oauth/token grant_type=authorization_code" do
    test "redeem code with PKCE", %{conn: conn} do
      user = register!()
      {client, secret} = register_client!()

      verifier = "verifier-1234567890abcdefghijklmn-and-some-more-bytes"
      challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

      {:ok, %{code: code}} =
        OAuth.create_authorization_code(user, client, ["read"],
          redirect_uri: "https://app.example/cb",
          code_challenge: challenge,
          code_challenge_method: "S256"
        )

      resp =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "client_id" => Integer.to_string(client.id),
          "client_secret" => secret,
          "code" => code,
          "redirect_uri" => "https://app.example/cb",
          "code_verifier" => verifier
        })

      body = json_response(resp, 200)
      assert is_binary(body["access_token"])
      # The grant the Pixelfed mobile app uses — must return a usable
      # refresh_token + expires_in so the app's token storage doesn't choke.
      assert is_binary(body["refresh_token"])
      assert is_integer(body["expires_in"]) and body["expires_in"] > 0
    end

    test "second redemption fails with invalid_grant", %{conn: conn} do
      user = register!()
      {client, secret} = register_client!()

      {:ok, %{code: code}} =
        OAuth.create_authorization_code(user, client, ["read"],
          redirect_uri: "https://app.example/cb"
        )

      params = %{
        "grant_type" => "authorization_code",
        "client_id" => Integer.to_string(client.id),
        "client_secret" => secret,
        "code" => code,
        "redirect_uri" => "https://app.example/cb"
      }

      _ = post(conn, ~p"/oauth/token", params)
      resp = post(conn, ~p"/oauth/token", params)
      assert json_response(resp, 400)["error"] == "invalid_grant"
    end
  end

  describe "POST /oauth/token grant_type=refresh_token" do
    test "400 unsupported by default", %{conn: conn} do
      {client, secret} = register_client!()

      resp =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "refresh_token",
          "client_id" => Integer.to_string(client.id),
          "client_secret" => secret,
          "refresh_token" => "x"
        })

      assert json_response(resp, 400)["error"] == "unsupported_grant_type"
    end
  end

  describe "POST /oauth/token unknown grant" do
    test "400 unsupported_grant_type", %{conn: conn} do
      resp = post(conn, ~p"/oauth/token", %{"grant_type" => "magic"})
      assert json_response(resp, 400)["error"] == "unsupported_grant_type"
    end
  end
end
