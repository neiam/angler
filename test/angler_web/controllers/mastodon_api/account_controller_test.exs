defmodule AnglerWeb.MastodonAPI.AccountControllerTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.{Accounts, OAuth}

  setup do
    {:ok, %{user: user, profile: profile}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123",
        name: "Alice"
      })

    %{client: client} = OAuth.first_party_client!()
    {:ok, %{access: access}} = OAuth.issue_token(user, client)

    %{user: user, profile: profile, access: access}
  end

  describe "GET /api/v1/accounts/verify_credentials" do
    test "401 without bearer", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/accounts/verify_credentials")
      assert json_response(conn, 401) == %{"error" => "The access token is invalid"}
    end

    test "401 with bogus bearer", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> get(~p"/api/v1/accounts/verify_credentials")

      assert json_response(conn, 401)
    end

    test "200 with valid bearer + read scope", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.access)
        |> get(~p"/api/v1/accounts/verify_credentials")

      body = json_response(conn, 200)
      assert body["username"] == "alice"
      assert body["display_name"] == "Alice"
      assert body["id"] == Integer.to_string(ctx.profile.id)
      assert body["source"]["privacy"] == "public"
      assert body["source"]["language"] == "en"
    end

    test "403 if scope is insufficient", ctx do
      %{client: client} = OAuth.first_party_client!()
      {:ok, %{access: narrow}} = OAuth.issue_token(ctx.user, client, scopes: ["write"])

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> narrow)
        |> get(~p"/api/v1/accounts/verify_credentials")

      body = json_response(conn, 403)
      assert body["error"] =~ "outside the authorized scopes"
    end
  end
end
