defmodule AnglerWeb.MastodonAPI.AppControllerTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.OAuth

  describe "POST /api/v1/apps" do
    test "200 with client_id + client_secret on happy path", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/apps", %{
          "client_name" => "MyClient",
          "redirect_uris" => "https://my-app.example/callback",
          "scopes" => "read write"
        })

      body = json_response(conn, 200)
      assert body["name"] == "MyClient"
      assert body["redirect_uri"] == "https://my-app.example/callback"
      assert body["redirect_uris"] == ["https://my-app.example/callback"]
      assert body["scopes"] == ["read", "write"]
      assert is_binary(body["client_id"])
      assert is_binary(body["client_secret"])
      assert byte_size(body["client_secret"]) > 30
      assert body["vapid_key"] == nil
      [origin] = get_resp_header(conn, "access-control-allow-origin")
      assert origin == "*"
    end

    test "accepts multiple redirect_uris separated by newline", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/apps", %{
          "client_name" => "Multi",
          "redirect_uris" => "https://a.example/cb\nhttps://b.example/cb"
        })

      body = json_response(conn, 200)
      assert length(body["redirect_uris"]) == 2
    end

    test "accepts urn:ietf:wg:oauth:2.0:oob", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/apps", %{
          "client_name" => "OOB",
          "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob"
        })

      body = json_response(conn, 200)
      assert body["redirect_uris"] == ["urn:ietf:wg:oauth:2.0:oob"]
    end

    test "html-escapes client_name on storage", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/apps", %{
          "client_name" => "<script>x</script>",
          "redirect_uris" => "https://a.example/cb"
        })

      body = json_response(conn, 200)
      refute body["name"] =~ "<script>"
      assert body["name"] =~ "&lt;script&gt;"
    end

    test "422 with errors when client_name missing", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/apps", %{"redirect_uris" => "https://a.example/cb"})
      body = json_response(conn, 422)
      assert body["error"] =~ "Validation"
      assert is_map(body["errors"])
    end

    test "422 when redirect_uris missing", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/apps", %{"client_name" => "MissingRedirect"})
      assert json_response(conn, 422)
    end

    test "422 when redirect_uri is invalid", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/apps", %{
          "client_name" => "BadRedirect",
          "redirect_uris" => "not a url"
        })

      assert json_response(conn, 422)
    end

    test "no auth required", %{conn: conn} do
      # Sanity check: no authorization header at all returns 200, not 401.
      conn =
        post(conn, ~p"/api/v1/apps", %{
          "client_name" => "Anon",
          "redirect_uris" => "https://a.example/cb"
        })

      assert json_response(conn, 200)
    end
  end

  describe "GET /api/v1/apps/verify_credentials" do
    setup do
      {:ok, %{user: user}} =
        Accounts.register(%{
          username: "alice",
          email: "alice@example.com",
          password: "verysecret123"
        })

      %{client: client} = OAuth.first_party_client!()
      {:ok, %{access: access}} = OAuth.issue_token(user, client)

      %{access: access, client_name: client.name}
    end

    test "200 with name + website + vapid_key for user-attached token", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.access)
        |> get(~p"/api/v1/apps/verify_credentials")

      body = json_response(conn, 200)
      assert body["name"] == ctx.client_name
      assert body["vapid_key"] == nil
      assert Map.has_key?(body, "website")
    end

    test "401 without bearer", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/apps/verify_credentials")
      assert json_response(conn, 401)
    end
  end
end
