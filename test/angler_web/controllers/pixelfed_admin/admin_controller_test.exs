defmodule AnglerWeb.PixelfedAdmin.AdminControllerTest do
  @moduledoc """
  Coverage for the Pixelfed-shape admin namespace at `/api/admin/...`.
  Distinct from the Mastodon-shape admin tests at `/api/v1/admin/...`.
  """

  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.Admin.ModLog
  alias Angler.Federation.Instance
  alias Angler.OAuth
  alias Angler.Profiles
  alias Angler.Reports
  alias Angler.Repo
  alias Angler.Statuses

  defp register_admin! do
    {:ok, %{user: user, profile: profile}} =
      Accounts.register(%{
        username: "mod",
        email: "mod@example.com",
        password: "verysecret123"
      })

    {:ok, user} =
      user
      |> Ecto.Changeset.change(is_admin: true, is_moderator: true)
      |> Repo.update()

    %{client: c} = OAuth.first_party_client!()
    {:ok, %{access: bearer}} = OAuth.issue_token(user, c, scopes: ["read", "write"])

    %{user: user, profile: profile, bearer: bearer}
  end

  defp register_user!(attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    {:ok, %{user: u, profile: p}} =
      Accounts.register(
        Map.merge(
          %{
            username: "u#{suffix}",
            email: "u#{suffix}@example.com",
            password: "passwordOK1"
          },
          attrs
        )
      )

    %{user: u, profile: p}
  end

  defp auth(conn, t), do: put_req_header(conn, "authorization", "Bearer " <> t)

  setup do
    Map.merge(register_admin!(), %{})
  end

  ## Auth gate

  describe "auth gate" do
    test "non-admin bearer → 403", %{conn: conn} do
      %{user: user} = register_user!()
      %{client: c} = OAuth.first_party_client!()
      {:ok, %{access: bearer}} = OAuth.issue_token(user, c, scopes: ["read"])

      assert json_response(auth(conn, bearer) |> get(~p"/api/admin/supported"), 403)
    end

    test "missing bearer → 401", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/admin/supported"), 401)
    end
  end

  ## Simple reads

  describe "GET /supported" do
    test "returns {supported: true}", ctx do
      assert %{"supported" => true} ==
               ctx.conn |> auth(ctx.bearer) |> get(~p"/api/admin/supported") |> json_response(200)
    end
  end

  describe "GET /stats" do
    test "returns counts", ctx do
      body = ctx.conn |> auth(ctx.bearer) |> get(~p"/api/admin/stats") |> json_response(200)
      assert body["user_count"] >= 1
      assert is_integer(body["pending_reports"])
      assert is_integer(body["profile_count"])
    end
  end

  describe "GET /instance/stats" do
    test "returns 7-day series for users/posts/instances", ctx do
      body =
        ctx.conn |> auth(ctx.bearer) |> get(~p"/api/admin/instance/stats") |> json_response(200)

      assert is_list(body["users"]["days"])
      assert length(body["users"]["days"]) == 7
      assert is_integer(body["users"]["total"])
    end
  end

  ## Mod reports

  describe "mod-reports" do
    test "list returns unresolved reports newest-first", ctx do
      %{user: reporter} = register_user!()
      %{profile: target} = register_user!()

      {:ok, _} =
        Reports.submit(reporter, %{
          "report_type" => "spam",
          "object_type" => "user",
          "object_id" => Integer.to_string(target.id)
        })

      body =
        ctx.conn
        |> auth(ctx.bearer)
        |> get(~p"/api/admin/mod-reports/list")
        |> json_response(200)

      assert [row | _] = body
      assert row["type"] == "spam"
      assert row["account"]["username"] == target.username
    end

    test "handle ignore marks the report resolved", ctx do
      %{user: reporter} = register_user!()
      %{profile: target} = register_user!()

      {:ok, report} =
        Reports.submit(reporter, %{
          "report_type" => "spam",
          "object_type" => "user",
          "object_id" => Integer.to_string(target.id)
        })

      assert %{"success" => true} =
               ctx.conn
               |> auth(ctx.bearer)
               |> post(~p"/api/admin/mod-reports/handle", %{
                 "id" => Integer.to_string(report.id),
                 "action" => "ignore"
               })
               |> json_response(200)

      reloaded = Repo.get!(Angler.Reports.Report, report.id)
      assert reloaded.resolved_at
    end

    test "handle cw flips is_nsfw on the reported status", ctx do
      %{user: reporter} = register_user!()
      %{user: _, profile: author} = register_user!()

      {:ok, status} =
        Statuses.create_local(author, %{
          "status" => "spicy content",
          "visibility" => "public"
        })

      {:ok, report} =
        Reports.submit(reporter, %{
          "report_type" => "sensitive",
          "object_type" => "post",
          "object_id" => Integer.to_string(status.id)
        })

      _ =
        ctx.conn
        |> auth(ctx.bearer)
        |> post(~p"/api/admin/mod-reports/handle", %{
          "id" => Integer.to_string(report.id),
          "action" => "cw"
        })
        |> json_response(200)

      assert Repo.get!(Angler.Statuses.Status, status.id).is_nsfw == true
    end

    test "handle rejects unknown action", ctx do
      assert json_response(
               ctx.conn
               |> auth(ctx.bearer)
               |> post(~p"/api/admin/mod-reports/handle", %{"id" => "1", "action" => "bogus"}),
               400
             )
    end
  end

  ## Autospam stubs

  test "GET /autospam/list returns []", ctx do
    assert [] ==
             ctx.conn
             |> auth(ctx.bearer)
             |> get(~p"/api/admin/autospam/list")
             |> json_response(200)
  end

  test "POST /autospam/handle 404 (no appeals)", ctx do
    assert json_response(
             ctx.conn |> auth(ctx.bearer) |> post(~p"/api/admin/autospam/handle"),
             404
           )
  end

  ## Configuration

  describe "config" do
    test "GET returns the toggle list with current state", ctx do
      body = ctx.conn |> auth(ctx.bearer) |> get(~p"/api/admin/config") |> json_response(200)
      keys = Enum.map(body, & &1["key"])
      assert "stories_enabled" in keys
      assert "open_registration" in keys
    end

    test "POST update flips a key", ctx do
      Application.delete_env(:angler, :stories_enabled)

      body =
        ctx.conn
        |> auth(ctx.bearer)
        |> post(~p"/api/admin/config/update", %{"key" => "stories_enabled", "value" => "true"})
        |> json_response(200)

      stories = Enum.find(body, &(&1["key"] == "stories_enabled"))
      assert stories["state"] == true
      assert Application.get_env(:angler, :stories_enabled) == true

      on_exit(fn -> Application.delete_env(:angler, :stories_enabled) end)
    end

    test "POST rejects unknown key", ctx do
      assert json_response(
               ctx.conn
               |> auth(ctx.bearer)
               |> post(~p"/api/admin/config/update", %{
                 "key" => "instance.uplink_to_skynet",
                 "value" => "true"
               }),
               400
             )
    end
  end

  ## Users

  describe "users" do
    test "list paginates active users", ctx do
      _ = register_user!(%{username: "alice"})
      _ = register_user!(%{username: "bob"})

      body =
        ctx.conn |> auth(ctx.bearer) |> get(~p"/api/admin/users/list") |> json_response(200)

      assert is_list(body["data"])
      assert length(body["data"]) >= 2
    end

    test "get returns user with meta", ctx do
      %{user: target} = register_user!(%{username: "carol"})

      body =
        ctx.conn
        |> auth(ctx.bearer)
        |> get(~p"/api/admin/users/get?user_id=#{target.id}")
        |> json_response(200)

      assert body["username"] == "carol"
      assert body["meta"]["account"]["username"] == "carol"
    end

    test "action verify_email sets email_verified_at", ctx do
      %{user: target} = register_user!()

      _ =
        ctx.conn
        |> auth(ctx.bearer)
        |> post(~p"/api/admin/users/action", %{
          "id" => Integer.to_string(target.id),
          "action" => "verify_email"
        })
        |> json_response(200)

      reloaded = Repo.get!(Angler.Accounts.User, target.id)
      assert reloaded.email_verified_at
    end

    test "action unlisted toggles flag", ctx do
      %{user: target, profile: profile} = register_user!()
      assert profile.unlisted == false

      _ =
        ctx.conn
        |> auth(ctx.bearer)
        |> post(~p"/api/admin/users/action", %{
          "id" => Integer.to_string(target.id),
          "action" => "unlisted",
          "value" => "true"
        })
        |> json_response(200)

      assert Repo.get!(Profiles.Profile, profile.id).unlisted == true
    end

    test "action delete soft-marks status=delete", ctx do
      %{user: target} = register_user!()

      _ =
        ctx.conn
        |> auth(ctx.bearer)
        |> post(~p"/api/admin/users/action", %{
          "id" => Integer.to_string(target.id),
          "action" => "delete"
        })
        |> json_response(200)

      assert Repo.get!(Angler.Accounts.User, target.id).status == "delete"
    end

    test "cannot moderate admin accounts (except refresh_stats)", ctx do
      assert json_response(
               ctx.conn
               |> auth(ctx.bearer)
               |> post(~p"/api/admin/users/action", %{
                 "id" => Integer.to_string(ctx.user.id),
                 "action" => "delete"
               }),
               400
             )
    end
  end

  ## Instances

  describe "instances" do
    setup ctx do
      {:ok, inst} =
        Instance.upsert_changeset(%{
          domain: "remote.test",
          software: "pixelfed",
          version: "0.12"
        })
        |> Repo.insert()

      Map.put(ctx, :instance, inst)
    end

    test "list returns rows", ctx do
      body =
        ctx.conn |> auth(ctx.bearer) |> get(~p"/api/admin/instances/list") |> json_response(200)

      domains = Enum.map(body["data"], & &1["domain"])
      assert "remote.test" in domains
    end

    test "list filters by banned flag", ctx do
      _ =
        ctx.instance
        |> Instance.moderation_changeset(%{banned: true})
        |> Repo.update!()

      body =
        ctx.conn
        |> auth(ctx.bearer)
        |> get(~p"/api/admin/instances/list?filter=banned")
        |> json_response(200)

      assert Enum.any?(body["data"], &(&1["domain"] == "remote.test"))
    end

    test "get returns single instance", ctx do
      body =
        ctx.conn
        |> auth(ctx.bearer)
        |> get(~p"/api/admin/instances/get?id=#{ctx.instance.id}")
        |> json_response(200)

      assert body["domain"] == "remote.test"
    end

    test "moderate flips a flag and writes a mod_log", ctx do
      _ =
        ctx.conn
        |> auth(ctx.bearer)
        |> post(~p"/api/admin/instances/moderate", %{
          "id" => Integer.to_string(ctx.instance.id),
          "key" => "unlisted",
          "value" => "true"
        })
        |> json_response(200)

      assert Repo.get!(Instance, ctx.instance.id).unlisted == true
      assert Repo.aggregate(ModLog, :count, :id) >= 1
    end

    test "moderate rejects unknown key", ctx do
      assert json_response(
               ctx.conn
               |> auth(ctx.bearer)
               |> post(~p"/api/admin/instances/moderate", %{
                 "id" => Integer.to_string(ctx.instance.id),
                 "key" => "evil",
                 "value" => "true"
               }),
               400
             )
    end

    test "refresh-stats recomputes counters from local data", ctx do
      _ =
        ctx.conn
        |> auth(ctx.bearer)
        |> post(~p"/api/admin/instances/refresh-stats", %{
          "id" => Integer.to_string(ctx.instance.id)
        })
        |> json_response(200)

      reloaded = Repo.get!(Instance, ctx.instance.id)
      assert reloaded.user_count == 0
      assert reloaded.status_count == 0
    end
  end

  ## Post moderation

  describe "moderate/post" do
    test "cw flips is_nsfw", ctx do
      %{profile: author} = register_user!()
      {:ok, status} = Statuses.create_local(author, %{"status" => "x", "visibility" => "public"})

      _ =
        ctx.conn
        |> auth(ctx.bearer)
        |> post(~p"/api/admin/moderate/post/#{status.id}", %{"action" => "cw"})
        |> json_response(200)

      assert Repo.get!(Angler.Statuses.Status, status.id).is_nsfw == true
    end

    test "delete soft-deletes the status", ctx do
      %{profile: author} = register_user!()
      {:ok, status} = Statuses.create_local(author, %{"status" => "x", "visibility" => "public"})

      _ =
        ctx.conn
        |> auth(ctx.bearer)
        |> post(~p"/api/admin/moderate/post/#{status.id}", %{"action" => "delete"})
        |> json_response(200)

      assert Repo.get!(Angler.Statuses.Status, status.id).deleted_at
    end

    test "rejects when target is an admin", ctx do
      {:ok, status} =
        Statuses.create_local(ctx.profile, %{"status" => "y", "visibility" => "public"})

      assert json_response(
               ctx.conn
               |> auth(ctx.bearer)
               |> post(~p"/api/admin/moderate/post/#{status.id}", %{"action" => "cw"}),
               400
             )
    end
  end
end
