defmodule AnglerWeb.MastodonAPI.Tier1EndpointsTest do
  @moduledoc """
  Coverage for the Tier-1 endpoints — the things mobile clients hit on
  every login or routinely thereafter:

    * Mastodon v1 stubs / aliases (`statuses/:id/card`, `accounts/:id/lists`,
      `trends`, `tags/:id/related`)
    * v1 actions (`accounts/:id/remove_from_followers`, endorse pin/unpin,
      `avatar/update`)
    * v2 (`streaming/config`)
    * Pixelfed v1.1 (`accounts/timelines/home`, `nag/state`,
      `status/create`, push state/compare/update/disable, admin invite
      verify/uc/ec)
  """

  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.Follows
  alias Angler.Invites.AdminInvite
  alias Angler.OAuth
  alias Angler.Profiles
  alias Angler.Repo

  @fixture Path.join([__DIR__, "..", "..", "..", "fixtures", "red.jpg"])

  setup do
    {:ok, %{user: u, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: c} = OAuth.first_party_client!()
    {:ok, %{access: read}} = OAuth.issue_token(u, c, scopes: ["read"])
    {:ok, %{access: write}} = OAuth.issue_token(u, c, scopes: ["write"])

    %{alice: alice, user: u, read: read, write: write}
  end

  defp auth(conn, t), do: put_req_header(conn, "authorization", "Bearer " <> t)

  defp upload_fixture do
    src = Path.join(System.tmp_dir!(), "tier1-#{System.unique_integer([:positive])}.jpg")
    File.cp!(@fixture, src)
    %Plug.Upload{path: src, filename: "red.jpg", content_type: "image/jpeg"}
  end

  ## v1 stubs

  describe "v1 stubs" do
    test "GET /statuses/:id/card returns {}", ctx do
      assert %{} ==
               ctx.conn
               |> auth(ctx.read)
               |> get(~p"/api/v1/statuses/123/card")
               |> json_response(200)
    end

    test "GET /accounts/:id/lists returns []", ctx do
      assert [] ==
               ctx.conn
               |> auth(ctx.read)
               |> get(~p"/api/v1/accounts/#{ctx.alice.id}/lists")
               |> json_response(200)
    end

    test "GET /trends returns []", ctx do
      assert [] == ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/trends") |> json_response(200)
    end

    test "GET /tags/:id/related returns []", ctx do
      assert [] ==
               ctx.conn
               |> auth(ctx.read)
               |> get(~p"/api/v1/tags/elixir/related")
               |> json_response(200)
    end
  end

  ## v2 streaming/config

  test "GET /api/v2/streaming/config returns {}", %{conn: conn} do
    assert %{} == get(conn, ~p"/api/v2/streaming/config") |> json_response(200)
  end

  ## remove_from_followers

  describe "POST /accounts/:id/remove_from_followers" do
    test "drops bob from alice's follower list", ctx do
      {:ok, %{profile: bob}} =
        Accounts.register(%{
          username: "bob",
          email: "bob@example.com",
          password: "passwordOK1"
        })

      {:ok, :accepted, _} = Follows.follow(bob, ctx.alice)

      body =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1/accounts/#{Integer.to_string(bob.id)}/remove_from_followers")
        |> json_response(200)

      assert body["followed_by"] == false
      assert is_nil(Follows.get_follower(ctx.alice.id, bob.id))
    end

    test "422 when target is self", ctx do
      assert json_response(
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1/accounts/#{ctx.alice.id}/remove_from_followers"),
               422
             )
    end
  end

  ## endorsements (no-op)

  describe "POST /accounts/:id/{pin,unpin}" do
    test "pin and unpin both return the relationship", ctx do
      {:ok, bob} = Profiles.create_profile(%{username: "bob"})

      assert %{"id" => _} =
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1/accounts/#{bob.id}/pin")
               |> json_response(200)

      assert %{"id" => _} =
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1/accounts/#{bob.id}/unpin")
               |> json_response(200)
    end
  end

  ## avatar/update

  describe "POST /avatar/update" do
    test "round-trips the upload through the credentials path", ctx do
      root = Path.join([System.tmp_dir!(), "tier1-avatar-#{System.unique_integer([:positive])}"])
      File.mkdir_p!(root)
      Application.put_env(:angler, :media_root, root)

      on_exit(fn ->
        Application.delete_env(:angler, :media_root)
        File.rm_rf!(root)
      end)

      body =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1/avatar/update", %{"avatar" => upload_fixture()})
        |> json_response(200)

      assert body["username"] == "alice"
      assert is_binary(body["avatar"]) and body["avatar"] != ""
    end

    test "422 when file missing", ctx do
      assert json_response(
               ctx.conn |> auth(ctx.write) |> post(~p"/api/v1/avatar/update"),
               422
             )
    end
  end

  ## v1.1 simple stubs

  describe "v1.1 reads" do
    test "GET /nag/state returns active=false by default", ctx do
      body = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1.1/nag/state") |> json_response(200)
      assert body == %{"active" => false}
    end

    test "GET /accounts/timelines/home returns the same shape as the Mastodon home", ctx do
      assert is_list(
               ctx.conn
               |> auth(ctx.read)
               |> get(~p"/api/v1.1/accounts/timelines/home")
               |> json_response(200)
             )
    end
  end

  ## v1.1 status/create

  describe "POST /api/v1.1/status/create" do
    test "uploads a photo + creates a public status", ctx do
      root = Path.join([System.tmp_dir!(), "tier1-sc-#{System.unique_integer([:positive])}"])
      File.mkdir_p!(root)
      Application.put_env(:angler, :media_root, root)

      on_exit(fn ->
        Application.delete_env(:angler, :media_root)
        File.rm_rf!(root)
      end)

      body =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/status/create", %{
          "file" => upload_fixture(),
          "status" => "hello tier-1",
          "visibility" => "public"
        })
        |> json_response(200)

      assert body["content"] =~ "hello tier-1" or body["content"] == "<p>hello tier-1</p>"
      assert body["visibility"] == "public"
      assert body["card"] == nil
      assert is_list(body["media_attachments"])
    end

    test "422 without a file", ctx do
      assert json_response(
               ctx.conn |> auth(ctx.write) |> post(~p"/api/v1.1/status/create"),
               422
             )
    end
  end

  ## v1.1 Pixelfed Expo push

  describe "Pixelfed Expo push" do
    setup do
      Application.put_env(:angler, :expo_push_enabled, true)
      on_exit(fn -> Application.delete_env(:angler, :expo_push_enabled) end)
      :ok
    end

    defp push_auth(conn, t),
      do:
        conn
        |> put_req_header("authorization", "Bearer " <> t)
        |> put_req_header("x-pixelfed-app", "1")

    test "404 without X-PIXELFED-APP header", ctx do
      assert json_response(
               ctx.conn |> auth(ctx.read) |> get(~p"/api/v1.1/push/state"),
               404
             )
    end

    test "404 when expo push disabled", ctx do
      Application.put_env(:angler, :expo_push_enabled, false)

      assert json_response(
               ctx.conn |> push_auth(ctx.read) |> get(~p"/api/v1.1/push/state"),
               404
             )
    end

    test "state → update → state → disable round-trip", ctx do
      empty =
        ctx.conn |> push_auth(ctx.read) |> get(~p"/api/v1.1/push/state") |> json_response(200)

      assert empty["has_token"] == false

      _ =
        ctx.conn
        |> push_auth(ctx.write)
        |> post(~p"/api/v1.1/push/update", %{
          "token" => "ExponentPushToken[abc-DEF_123]",
          "notify_enabled" => "true",
          "notify_like" => "true"
        })
        |> json_response(200)

      after_set =
        ctx.conn |> push_auth(ctx.read) |> get(~p"/api/v1.1/push/state") |> json_response(200)

      assert after_set["has_token"] == true
      assert after_set["notify_enabled"] == true
      assert after_set["notify_like"] == true

      cmp =
        ctx.conn
        |> push_auth(ctx.write)
        |> post(~p"/api/v1.1/push/compare", %{"expo_token" => "ExponentPushToken[abc-DEF_123]"})
        |> json_response(200)

      assert cmp["match"] == true
      assert cmp["has_existing"] == true

      mismatched =
        ctx.conn
        |> push_auth(ctx.write)
        |> post(~p"/api/v1.1/push/compare", %{"expo_token" => "ExponentPushToken[xyz]"})
        |> json_response(200)

      assert mismatched["match"] == false
      assert mismatched["has_existing"] == true

      cleared =
        ctx.conn |> push_auth(ctx.write) |> post(~p"/api/v1.1/push/disable") |> json_response(200)

      assert cleared["has_token"] == false
      assert cleared["notify_enabled"] == false
    end

    test "update rejects malformed token", ctx do
      assert json_response(
               ctx.conn
               |> push_auth(ctx.write)
               |> post(~p"/api/v1.1/push/update", %{"token" => "not-an-expo-token"}),
               422
             )
    end
  end

  ## v1.1 admin invite verification

  describe "admin invite checks" do
    test "verify 404 when no invite seeded", %{conn: conn} do
      assert json_response(
               post(conn, ~p"/api/v1.1/auth/invite/admin/verify", %{"token" => "missing"}),
               404
             )
    end

    test "verify returns invite metadata", %{conn: conn} do
      seed_invite!(%{invite_code: "WELCOME-ABC", message: "join us", max_uses: 5})

      body =
        post(conn, ~p"/api/v1.1/auth/invite/admin/verify", %{"token" => "WELCOME-ABC"})
        |> json_response(200)

      assert body["message"] == "join us"
      assert body["max_uses"] == 5
      assert body["sev"] == false
    end

    test "verify rejects expired invite", %{conn: conn} do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      seed_invite!(%{invite_code: "EXP-1", expires_at: past})

      assert json_response(
               post(conn, ~p"/api/v1.1/auth/invite/admin/verify", %{"token" => "EXP-1"}),
               400
             )
    end

    test "verify rejects exhausted invite", %{conn: conn} do
      seed_invite!(%{invite_code: "DONE-1", max_uses: 1, uses: 1})

      assert json_response(
               post(conn, ~p"/api/v1.1/auth/invite/admin/verify", %{"token" => "DONE-1"}),
               400
             )
    end

    test "uc validates username availability", %{conn: conn} do
      seed_invite!(%{invite_code: "OK-1"})

      assert %{} ==
               post(conn, ~p"/api/v1.1/auth/invite/admin/uc", %{
                 "token" => "OK-1",
                 "username" => "freshname"
               })
               |> json_response(200)
    end

    test "uc rejects taken username", %{conn: conn} do
      seed_invite!(%{invite_code: "OK-2"})

      assert json_response(
               post(conn, ~p"/api/v1.1/auth/invite/admin/uc", %{
                 "token" => "OK-2",
                 "username" => "alice"
               }),
               422
             )
    end

    test "ec rejects taken email", %{conn: conn} do
      seed_invite!(%{invite_code: "OK-3"})

      assert json_response(
               post(conn, ~p"/api/v1.1/auth/invite/admin/ec", %{
                 "token" => "OK-3",
                 "email" => "alice@example.com"
               }),
               422
             )
    end
  end

  defp seed_invite!(attrs) do
    full = Map.merge(%{id: Angler.Snowflake.next()}, attrs)

    {:ok, invite} =
      %AdminInvite{}
      |> AdminInvite.changeset(full)
      |> Repo.insert()

    invite
  end
end
