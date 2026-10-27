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

    test "200 with _pe=1 returns Pixelfed-extension fields", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.access)
        |> get(~p"/api/v1/accounts/verify_credentials?_pe=1")

      body = json_response(conn, 200)
      assert body["username"] == "alice"
      assert body["is_admin"] == false
      assert body["local"] == true
      assert body["pronouns"] == []
      assert is_map(body["settings"])
      assert is_boolean(body["settings"]["video_autoplay"])
      assert Map.has_key?(body, "note_text")
      assert Map.has_key?(body, "header_bg")
      assert Map.has_key?(body, "last_fetched_at")
      assert Map.has_key?(body, "location")
      assert Map.has_key?(body, "website")
      assert body["has_story"] == false
      assert body["moved"] == nil
      assert body["settings"]["default_scope"] == "public"
      assert body["settings"]["default_license"] == 1
    end

    test "moved renders the target account's short form", ctx do
      {:ok, target} = Angler.Profiles.create_profile(%{username: "newhome"})

      ctx.profile
      |> Ecto.Changeset.change(moved_to_id: target.id)
      |> Angler.Repo.update!()

      body =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.access)
        |> get(~p"/api/v1/accounts/verify_credentials")
        |> json_response(200)

      assert body["moved"]["id"] == Integer.to_string(target.id)
      assert body["moved"]["acct"] == "newhome"
    end

    test "200 without _pe omits extension fields (back-compat)", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.access)
        |> get(~p"/api/v1/accounts/verify_credentials")

      body = json_response(conn, 200)
      refute Map.has_key?(body, "is_admin")
      refute Map.has_key?(body, "settings")
      refute Map.has_key?(body, "pronouns")
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
