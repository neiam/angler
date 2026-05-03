defmodule Angler.Integration.OAuthAuthorizeE2ETest do
  @moduledoc """
  Browser-flow end-to-end:

    1. GET /oauth/authorize — unauthenticated → redirect to /session/login.
    2. POST /session/login — sets the cookie, redirects back.
    3. GET /oauth/authorize — renders the consent form.
    4. POST /oauth/authorize — issues a code, redirects to redirect_uri?code=...
    5. POST /oauth/token — exchanges the code for an access token.
    6. GET /api/v1/accounts/verify_credentials — bearer works.
  """

  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.OAuth

  setup do
    {:ok, %{user: user, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    {:ok, %{client: client, secret: secret}} =
      OAuth.register_client(%{
        "client_name" => "BrowserApp",
        "redirect_uris" => "https://app.example/cb",
        "scopes" => "read write"
      })

    %{user: user, alice: alice, client: client, secret: secret}
  end

  test "happy-path consent flow yields a working bearer token", ctx do
    cid = Integer.to_string(ctx.client.id)
    redirect_uri = "https://app.example/cb"

    authorize_path =
      "/oauth/authorize?response_type=code&client_id=#{cid}" <>
        "&redirect_uri=#{URI.encode_www_form(redirect_uri)}&scope=read"

    # 1. Unauthenticated GET → 302 to /session/login.
    conn = build_conn() |> get(authorize_path)
    assert redirected_to(conn, 302) =~ "/session/login"

    # 2. POST /session/login carrying the next param.
    conn =
      build_conn()
      |> post(~p"/session/login", %{
        "username" => "alice",
        "password" => "verysecret123",
        "next" => authorize_path
      })

    assert redirected_to(conn, 302) == authorize_path

    # 3. GET /oauth/authorize with the session cookie present.
    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: ctx.user.id)
      |> get(authorize_path)

    body = html_response(conn, 200)
    assert body =~ "BrowserApp"
    assert body =~ "Approve"

    # 4. POST /oauth/authorize, approve.
    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: ctx.user.id)
      |> post(~p"/oauth/authorize", %{
        "approve" => "true",
        "client_id" => cid,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => "read"
      })

    location = get_resp_header(conn, "location") |> List.first()
    assert location, "expected redirect with code"
    assert String.starts_with?(location, redirect_uri <> "?code=")
    code = location |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("code")
    assert is_binary(code)

    # 5. Exchange code at /oauth/token.
    conn =
      build_conn()
      |> post(~p"/oauth/token", %{
        "grant_type" => "authorization_code",
        "client_id" => cid,
        "client_secret" => ctx.secret,
        "code" => code,
        "redirect_uri" => redirect_uri
      })

    %{"access_token" => access} = json_response(conn, 200)

    # 6. Use the bearer.
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> access)
      |> get(~p"/api/v1/accounts/verify_credentials")

    body = json_response(conn, 200)
    assert body["username"] == "alice"
  end

  test "deny flow redirects with error=access_denied", ctx do
    cid = Integer.to_string(ctx.client.id)
    redirect_uri = "https://app.example/cb"

    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: ctx.user.id)
      |> post(~p"/oauth/authorize", %{
        "client_id" => cid,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => "read"
      })

    location = get_resp_header(conn, "location") |> List.first()
    assert location =~ "error=access_denied"
  end

  test "OOB redirect renders the code on a confirmation page", ctx do
    {:ok, %{client: oob_client, secret: _}} =
      OAuth.register_client(%{
        "client_name" => "OOBApp",
        "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
        "scopes" => "read"
      })

    cid = Integer.to_string(oob_client.id)

    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: ctx.user.id)
      |> post(~p"/oauth/authorize", %{
        "approve" => "true",
        "client_id" => cid,
        "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
        "response_type" => "code",
        "scope" => "read"
      })

    body = html_response(conn, 200)
    assert body =~ "Authorization code"
  end

  test "GET with disallowed redirect_uri returns 400", ctx do
    cid = Integer.to_string(ctx.client.id)

    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: ctx.user.id)
      |> get(
        ~p"/oauth/authorize?response_type=code&client_id=#{cid}" <>
          "&redirect_uri=https://attacker.example/cb&scope=read"
      )

    assert html_response(conn, 400) =~ "redirect_uri not allowed"
  end
end
