defmodule AnglerWeb.GroupsAPI.GroupsTest do
  @moduledoc """
  Coverage for `/api/v0/groups/...`. Whole feature is gated by
  `:groups_enabled` (default false) — every test enables it in setup.
  """

  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.Groups
  alias Angler.Groups.{Group, Member}
  alias Angler.OAuth
  alias Angler.Repo

  setup do
    Application.put_env(:angler, :groups_enabled, true)
    on_exit(fn -> Application.delete_env(:angler, :groups_enabled) end)

    {:ok, %{user: u, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: c} = OAuth.first_party_client!()
    {:ok, %{access: read}} = OAuth.issue_token(u, c, scopes: ["read"])
    {:ok, %{access: write}} = OAuth.issue_token(u, c, scopes: ["write"])

    %{alice: alice, read: read, write: write}
  end

  defp auth(conn, t), do: put_req_header(conn, "authorization", "Bearer " <> t)

  defp register_other!(suffix \\ nil) do
    s = suffix || System.unique_integer([:positive])

    {:ok, %{user: u, profile: p}} =
      Accounts.register(%{
        username: "u#{s}",
        email: "u#{s}@example.com",
        password: "passwordOK1"
      })

    %{client: c} = OAuth.first_party_client!()
    {:ok, %{access: read}} = OAuth.issue_token(u, c, scopes: ["read"])
    {:ok, %{access: write}} = OAuth.issue_token(u, c, scopes: ["write"])

    %{user: u, profile: p, read: read, write: write}
  end

  ## Feature gate

  describe "feature gate" do
    test "404 on every endpoint when groups disabled", ctx do
      Application.put_env(:angler, :groups_enabled, false)

      assert json_response(
               ctx.conn |> auth(ctx.read) |> get(~p"/api/v0/groups/discover/popular"),
               404
             )

      assert json_response(
               ctx.conn |> auth(ctx.write) |> post(~p"/api/v0/groups/create", %{"name" => "x"}),
               404
             )
    end

    test "GET /config returns enabled flag regardless of state", ctx do
      Application.put_env(:angler, :groups_enabled, false)

      body =
        ctx.conn |> auth(ctx.read) |> get(~p"/api/v0/groups/config") |> json_response(200)

      assert body["enabled"] == false
    end
  end

  ## Lifecycle

  describe "lifecycle" do
    test "create + show round-trips", ctx do
      body =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v0/groups/create", %{
          "name" => "Photog Club",
          "description" => "Pictures of pictures",
          "privacy" => "public"
        })
        |> json_response(200)

      assert body["name"] == "Photog Club"
      assert body["slug"] == "photog-club"
      assert body["is_member"] == true
      assert body["member_count"] == 1

      shown =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v0/groups/#{body["id"]}")
        |> json_response(200)

      assert shown["id"] == body["id"]
    end

    test "create 422 when name missing", ctx do
      assert json_response(
               ctx.conn |> auth(ctx.write) |> post(~p"/api/v0/groups/create", %{}),
               422
             )
    end

    test "settings update is owner-only", ctx do
      {:ok, group} = Groups.create(ctx.alice, %{"name" => "Owners Only"})
      bob = register_other!()

      assert json_response(
               ctx.conn
               |> auth(bob.write)
               |> post(~p"/api/v0/groups/#{group.id}/settings", %{"description" => "hijacked"}),
               403
             )

      assert %{"description" => "owner edit"} =
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v0/groups/#{group.id}/settings", %{"description" => "owner edit"})
               |> json_response(200)
    end

    test "delete is owner-only", ctx do
      {:ok, group} = Groups.create(ctx.alice, %{"name" => "Doomed"})
      bob = register_other!()

      assert json_response(
               ctx.conn
               |> auth(bob.write)
               |> post(~p"/api/v0/groups/delete", %{"id" => Integer.to_string(group.id)}),
               403
             )

      assert %{"code" => 200} =
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v0/groups/delete", %{"id" => Integer.to_string(group.id)})
               |> json_response(200)

      refute Repo.get(Group, group.id)
    end
  end

  ## Membership

  describe "membership" do
    test "join a public group is instant", ctx do
      {:ok, group} = Groups.create(ctx.alice, %{"name" => "Public Square"})
      bob = register_other!()

      body =
        ctx.conn
        |> auth(bob.write)
        |> post(~p"/api/v0/groups/#{group.id}/join")
        |> json_response(200)

      assert body["state"] == "member"
      assert Repo.aggregate(Member, :count, :id) == 2
      assert Repo.get!(Group, group.id).member_count == 2
    end

    test "join a private group is pending", ctx do
      {:ok, group} = Groups.create(ctx.alice, %{"name" => "Quiet Place", "privacy" => "private"})
      bob = register_other!()

      body =
        ctx.conn
        |> auth(bob.write)
        |> post(~p"/api/v0/groups/#{group.id}/join")
        |> json_response(200)

      assert body["state"] == "pending"

      pending = Repo.all(Member) |> Enum.find(&is_nil(&1.accepted_at))
      assert pending.role == "member"
      assert pending.profile_id == bob.profile.id
    end

    test "owner approves a pending request", ctx do
      {:ok, group} = Groups.create(ctx.alice, %{"name" => "Closed", "privacy" => "private"})
      bob = register_other!()

      _ =
        ctx.conn
        |> auth(bob.write)
        |> post(~p"/api/v0/groups/#{group.id}/join")
        |> json_response(200)

      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v0/groups/members/request", %{
          "id" => Integer.to_string(group.id),
          "pid" => Integer.to_string(bob.profile.id)
        })
        |> json_response(200)

      assert Groups.member?(group, bob.profile)
    end

    test "leave drops the membership and decrements count", ctx do
      {:ok, group} = Groups.create(ctx.alice, %{"name" => "Open"})
      bob = register_other!()
      {:ok, :member, _} = Groups.join(bob.profile, group)
      assert Repo.get!(Group, group.id).member_count == 2

      _ =
        ctx.conn
        |> auth(bob.write)
        |> post(~p"/api/v0/groups/#{group.id}/leave")
        |> json_response(200)

      refute Groups.member?(group, bob.profile)
      assert Repo.get!(Group, group.id).member_count == 1
    end

    test "owner cannot leave their own group", ctx do
      {:ok, group} = Groups.create(ctx.alice, %{"name" => "Forever Mine"})

      assert json_response(
               ctx.conn |> auth(ctx.write) |> post(~p"/api/v0/groups/#{group.id}/leave"),
               422
             )
    end

    test "members list shows accepted members only", ctx do
      {:ok, group} = Groups.create(ctx.alice, %{"name" => "Open House"})
      bob = register_other!()
      {:ok, :member, _} = Groups.join(bob.profile, group)

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v0/groups/members/list?id=#{group.id}")
        |> json_response(200)

      usernames = Enum.map(body, & &1["account"]["username"])
      assert "alice" in usernames
      assert bob.profile.username in usernames
    end
  end

  ## Posts + comments

  describe "posts + comments" do
    test "store_post creates a status with group_id and bumps post_count", ctx do
      {:ok, group} = Groups.create(ctx.alice, %{"name" => "Posters"})

      body =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v0/groups/status/new", %{
          "id" => Integer.to_string(group.id),
          "status" => "hello group",
          "visibility" => "public"
        })
        |> json_response(200)

      assert body["content"] =~ "hello"
      reloaded = Repo.get!(Group, group.id)
      assert reloaded.post_count == 1
    end

    test "non-members cannot post", ctx do
      {:ok, group} = Groups.create(ctx.alice, %{"name" => "Members Only"})
      bob = register_other!()

      assert json_response(
               ctx.conn
               |> auth(bob.write)
               |> post(~p"/api/v0/groups/status/new", %{
                 "id" => Integer.to_string(group.id),
                 "status" => "trespass"
               }),
               403
             )
    end

    test "feed lists posts newest-first", ctx do
      {:ok, group} = Groups.create(ctx.alice, %{"name" => "Feed"})

      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v0/groups/status/new", %{
          "id" => Integer.to_string(group.id),
          "status" => "first"
        })
        |> json_response(200)

      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v0/groups/status/new", %{
          "id" => Integer.to_string(group.id),
          "status" => "second"
        })
        |> json_response(200)

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v0/groups/#{group.id}/feed")
        |> json_response(200)

      assert length(body) == 2
      assert hd(body)["content"] =~ "second"
    end

    test "store_comment threads a reply onto a group post", ctx do
      {:ok, group} = Groups.create(ctx.alice, %{"name" => "Chatty"})
      bob = register_other!()
      {:ok, :member, _} = Groups.join(bob.profile, group)

      post_body =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v0/groups/status/new", %{
          "id" => Integer.to_string(group.id),
          "status" => "anyone there?"
        })
        |> json_response(200)

      _ =
        ctx.conn
        |> auth(bob.write)
        |> post(~p"/api/v0/groups/comment", %{
          "id" => Integer.to_string(group.id),
          "sid" => post_body["id"],
          "caption" => "yes!"
        })
        |> json_response(200)

      replies =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v0/groups/comments?id=#{group.id}&sid=#{post_body["id"]}")
        |> json_response(200)

      assert [reply] = replies
      assert reply["content"] =~ "yes!"
    end
  end

  ## Discovery + search

  describe "discovery + search" do
    test "discover/popular surfaces public discoverable groups", ctx do
      {:ok, _} = Groups.create(ctx.alice, %{"name" => "Photogs"})

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v0/groups/discover/popular")
        |> json_response(200)

      names = Enum.map(body, & &1["name"])
      assert "Photogs" in names
    end

    test "search/global ILIKEs on group name", ctx do
      {:ok, _} = Groups.create(ctx.alice, %{"name" => "Cooking Club"})
      {:ok, _} = Groups.create(ctx.alice, %{"name" => "Hiking Crew"})

      body =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v0/groups/search/global", %{"q" => "cook"})
        |> json_response(200)

      assert [hit] = body
      assert hit["name"] == "Cooking Club"
    end

    test "self/list returns groups the viewer is in", ctx do
      {:ok, _} = Groups.create(ctx.alice, %{"name" => "Mine"})
      bob = register_other!()

      body =
        ctx.conn
        |> auth(bob.read)
        |> get(~p"/api/v0/groups/self/list")
        |> json_response(200)

      assert body == []
    end
  end

  ## Admin

  describe "admin" do
    test "blocks add then list, owner-only", ctx do
      {:ok, group} = Groups.create(ctx.alice, %{"name" => "Tight"})
      bob = register_other!()

      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v0/groups/#{group.id}/admin/blocks/add", %{
          "pid" => Integer.to_string(bob.profile.id),
          "reason" => "trolling"
        })
        |> json_response(200)

      list =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v0/groups/#{group.id}/admin/blocks")
        |> json_response(200)

      assert [b] = list
      assert b["reason"] == "trolling"

      assert json_response(
               ctx.conn
               |> auth(bob.write)
               |> post(~p"/api/v0/groups/#{group.id}/admin/blocks/add", %{
                 "pid" => Integer.to_string(ctx.alice.id)
               }),
               403
             )
    end

    test "blocked profile cannot join", ctx do
      {:ok, group} = Groups.create(ctx.alice, %{"name" => "Bouncer"})
      bob = register_other!()

      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v0/groups/#{group.id}/admin/blocks/add", %{
          "pid" => Integer.to_string(bob.profile.id)
        })
        |> json_response(200)

      assert json_response(
               ctx.conn |> auth(bob.write) |> post(~p"/api/v0/groups/#{group.id}/join"),
               403
             )
    end

    test "report create + resolve flow", ctx do
      {:ok, group} = Groups.create(ctx.alice, %{"name" => "Modlogged"})
      bob = register_other!()
      {:ok, :member, _} = Groups.join(bob.profile, group)

      _ =
        ctx.conn
        |> auth(bob.write)
        |> post(~p"/api/v0/groups/#{group.id}/report/create", %{
          "object_type" => "post",
          "object_id" => "1",
          "report_type" => "spam"
        })
        |> json_response(200)

      list =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v0/groups/#{group.id}/reports/list")
        |> json_response(200)

      assert [r] = list
      assert r["report_type"] == "spam"

      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v0/groups/#{group.id}/report/action", %{"report_id" => r["id"]})
        |> json_response(200)

      empty =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v0/groups/#{group.id}/reports/list")
        |> json_response(200)

      assert empty == []
    end
  end
end
