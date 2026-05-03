defmodule AnglerWeb.MastodonAPI.AccountProfileTest do
  @moduledoc """
  Tests for the profile-slice account endpoints: update_credentials, show,
  lookup, search, statuses, followers, blocks, mutes.
  """

  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.Follows
  alias Angler.OAuth
  alias Angler.Profiles
  alias Angler.Statuses

  @fixture Path.join([__DIR__, "..", "..", "..", "fixtures", "red.jpg"])

  setup do
    {:ok, %{user: user, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: client} = OAuth.first_party_client!()
    {:ok, %{access: read}} = OAuth.issue_token(user, client, scopes: ["read"])
    {:ok, %{access: write}} = OAuth.issue_token(user, client, scopes: ["write"])

    {:ok, bob} = Profiles.create_profile(%{username: "bob"})

    %{alice: alice, bob: bob, user: user, read: read, write: write}
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  describe "PATCH /accounts/update_credentials" do
    setup do
      root = Path.join([System.tmp_dir!(), "ang-acc-#{System.unique_integer([:positive])}"])
      File.mkdir_p!(root)
      Application.put_env(:angler, :media_root, root)

      on_exit(fn ->
        Application.delete_env(:angler, :media_root)
        File.rm_rf!(root)
      end)

      :ok
    end

    test "updates display_name + note + locked", ctx do
      conn =
        ctx.conn
        |> auth(ctx.write)
        |> patch(~p"/api/v1/accounts/update_credentials", %{
          "display_name" => "Alice Liddell",
          "note" => "Down the rabbit hole.",
          "locked" => "true"
        })

      body = json_response(conn, 200)
      assert body["display_name"] == "Alice Liddell"
      assert body["note"] =~ "rabbit hole"
      assert body["locked"] == true
    end

    test "uploads avatar via multipart", ctx do
      src = Path.join(System.tmp_dir!(), "ang-av-#{System.unique_integer([:positive])}.jpg")
      File.cp!(@fixture, src)

      conn =
        ctx.conn
        |> auth(ctx.write)
        |> patch(~p"/api/v1/accounts/update_credentials", %{
          "avatar" => %Plug.Upload{path: src, filename: "av.jpg", content_type: "image/jpeg"}
        })

      body = json_response(conn, 200)
      assert body["avatar"] =~ "/storage/m/v2/"
    end

    test "validation failure → 422", ctx do
      too_long = String.duplicate("x", 31)

      conn =
        ctx.conn
        |> auth(ctx.write)
        |> patch(~p"/api/v1/accounts/update_credentials", %{"display_name" => too_long})

      assert json_response(conn, 422)["error"] =~ "Validation"
    end

    test "401 without bearer", ctx do
      conn = patch(ctx.conn, ~p"/api/v1/accounts/update_credentials", %{})
      assert json_response(conn, 401)
    end
  end

  describe "GET /accounts/:id" do
    test "200 for existing account", ctx do
      conn =
        auth(ctx.conn, ctx.read) |> get(~p"/api/v1/accounts/#{Integer.to_string(ctx.bob.id)}")

      assert json_response(conn, 200)["username"] == "bob"
    end

    test "404 for unknown id", ctx do
      conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v1/accounts/999999999")
      assert json_response(conn, 404)
    end
  end

  describe "GET /accounts/lookup" do
    test "200 by acct", ctx do
      conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v1/accounts/lookup?acct=alice")
      assert json_response(conn, 200)["username"] == "alice"
    end

    test "404 unknown", ctx do
      conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v1/accounts/lookup?acct=nobody")
      assert json_response(conn, 404)
    end
  end

  describe "GET /accounts/search" do
    test "matches by username prefix", ctx do
      conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v1/accounts/search?q=al")
      [hit] = json_response(conn, 200)
      assert hit["username"] == "alice"
    end
  end

  describe "GET /accounts/:id/statuses" do
    test "returns the author's public statuses, omitting private", ctx do
      {:ok, s_pub} =
        Statuses.create_remote(%{
          profile_id: ctx.bob.id,
          visibility: :public,
          caption: "first",
          rendered: "<p>first</p>",
          type: "text",
          local: false,
          uri: "http://remote.test/notes/p1"
        })

      {:ok, _} =
        Statuses.create_remote(%{
          profile_id: ctx.bob.id,
          visibility: :private,
          caption: "secret",
          rendered: "<p>secret</p>",
          type: "text",
          local: false,
          uri: "http://remote.test/notes/p2"
        })

      conn =
        auth(ctx.conn, ctx.read)
        |> get(~p"/api/v1/accounts/#{Integer.to_string(ctx.bob.id)}/statuses")

      body = json_response(conn, 200)
      ids = Enum.map(body, & &1["id"])
      assert Integer.to_string(s_pub.id) in ids
      refute Enum.any?(body, &(&1["visibility"] == "private"))
    end
  end

  describe "GET /accounts/:id/followers" do
    test "lists followers when account is public", ctx do
      {:ok, _, _} = Follows.follow(ctx.alice, ctx.bob)

      conn =
        auth(ctx.conn, ctx.read)
        |> get(~p"/api/v1/accounts/#{Integer.to_string(ctx.bob.id)}/followers")

      [hit] = json_response(conn, 200)
      assert hit["username"] == "alice"
    end

    test "403 when target is locked and viewer doesn't follow", ctx do
      {:ok, locked} = Profiles.create_profile(%{username: "lockedup", is_private: true})

      conn =
        auth(ctx.conn, ctx.read)
        |> get(~p"/api/v1/accounts/#{Integer.to_string(locked.id)}/followers")

      assert json_response(conn, 403)
    end
  end

  describe "block/unblock + GET /blocks" do
    test "block tears down follow + appears in /blocks; relationship reflects it", ctx do
      {:ok, _, _} = Follows.follow(ctx.alice, ctx.bob)

      conn =
        auth(ctx.conn, ctx.write)
        |> post(~p"/api/v1/accounts/#{Integer.to_string(ctx.bob.id)}/block")

      rel = json_response(conn, 200)
      assert rel["blocking"] == true
      assert rel["following"] == false

      conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v1/blocks")
      assert [%{"username" => "bob"}] = json_response(conn, 200)

      conn =
        auth(ctx.conn, ctx.write)
        |> post(~p"/api/v1/accounts/#{Integer.to_string(ctx.bob.id)}/unblock")

      assert json_response(conn, 200)["blocking"] == false
    end
  end

  describe "mute/unmute + GET /mutes" do
    test "mute appears in /mutes and reflects in relationships", ctx do
      conn =
        auth(ctx.conn, ctx.write)
        |> post(~p"/api/v1/accounts/#{Integer.to_string(ctx.bob.id)}/mute")

      assert json_response(conn, 200)["muting"] == true

      conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v1/mutes")
      assert [%{"username" => "bob"}] = json_response(conn, 200)
    end
  end

  describe "blocks hide blocked accounts from public timeline" do
    test "public timeline omits blocked author", ctx do
      {:ok, s} =
        Statuses.create_remote(%{
          profile_id: ctx.bob.id,
          visibility: :public,
          caption: "x",
          rendered: "<p>x</p>",
          type: "text",
          local: false,
          uri: "http://remote.test/notes/blocker"
        })

      Angler.Profiles.BlocksMutes.block(ctx.alice, ctx.bob)

      conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v1/timelines/public")
      ids = json_response(conn, 200) |> Enum.map(& &1["id"])
      refute Integer.to_string(s.id) in ids
    end
  end
end
