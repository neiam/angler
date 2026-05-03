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
