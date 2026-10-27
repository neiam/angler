defmodule AnglerWeb.Admin.AdminNamespaceTest do
  @moduledoc """
  Coverage for the `/api/v1/admin/...` namespace: reports queue, accounts
  actions, instance + email domain blocks, announcements CRUD.
  """

  use AnglerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Angler.Accounts
  alias Angler.Admin
  alias Angler.OAuth
  alias Angler.Profiles
  alias Angler.Repo
  alias Angler.Reports.Report

  defp register_admin! do
    {:ok, %{user: user, profile: profile}} =
      Accounts.register(%{
        username: "mod",
        email: "mod@example.com",
        password: "verysecret123"
      })

    {:ok, user} = user |> Ecto.Changeset.change(is_admin: true) |> Repo.update()

    %{client: c} = OAuth.first_party_client!()

    {:ok, %{access: bearer}} =
      OAuth.issue_token(user, c, scopes: ["read", "write", "admin:read", "admin:write"])

    %{user: user, profile: profile, bearer: bearer}
  end

  defp register_user!(opts) do
    {:ok, %{user: user, profile: profile}} =
      Accounts.register(%{
        username: opts[:username] || "u#{System.unique_integer([:positive])}",
        email: opts[:email] || "u#{System.unique_integer([:positive])}@example.com",
        password: opts[:password] || "passwordOK1"
      })

    %{user: user, profile: profile}
  end

  defp auth(conn, t), do: put_req_header(conn, "authorization", "Bearer " <> t)

  ## Auth

  describe "auth gate" do
    test "non-admin bearer → 403", %{conn: conn} do
      %{user: user} = register_user!(username: "regular", email: "reg@example.com")
      %{client: c} = OAuth.first_party_client!()
      {:ok, %{access: bearer}} = OAuth.issue_token(user, c, scopes: ["read"])

      assert json_response(auth(conn, bearer) |> get(~p"/api/v1/admin/reports"), 403)
    end

    test "missing bearer → 401", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/v1/admin/reports"), 401)
    end

    test "an admin's token without admin scopes → 403", %{conn: conn} do
      %{user: admin} = register_admin!()
      %{client: c} = OAuth.first_party_client!()
      {:ok, %{access: bearer}} = OAuth.issue_token(admin, c, scopes: ["read", "write"])

      assert json_response(auth(conn, bearer) |> get(~p"/api/v1/admin/reports"), 403)

      assert json_response(
               auth(conn, bearer)
               |> post(~p"/api/v1/admin/domain_blocks", %{"domain" => "x.test"}),
               403
             )
    end
  end

  ## Reports queue

  describe "reports queue" do
    setup do
      admin = register_admin!()
      reporter = register_user!(username: "rp", email: "rp@example.com")
      {:ok, target} = Profiles.create_profile(%{username: "spammer"})

      {:ok, report} =
        Angler.Reports.submit(reporter.user, %{
          "report_type" => "spam",
          "object_id" => Integer.to_string(target.id),
          "object_type" => "user"
        })

      %{admin: admin, report: report, target: target}
    end

    test "GET /admin/reports lists open reports", ctx do
      [hit] =
        ctx.admin
        |> Map.get(:bearer)
        |> then(&auth(build_conn(), &1))
        |> get(~p"/api/v1/admin/reports?resolved=false")
        |> json_response(200)

      assert hit["id"] == Integer.to_string(ctx.report.id)
      assert hit["target_account"]["username"] == "spammer"
    end

    test "assign + resolve + reopen flow", ctx do
      conn = auth(build_conn(), ctx.admin.bearer)
      rid = Integer.to_string(ctx.report.id)

      assigned =
        conn
        |> post(~p"/api/v1/admin/reports/#{rid}/assign_to_self")
        |> json_response(200)

      assert assigned["assigned_account"]["username"] == "mod"

      resolved =
        conn
        |> post(~p"/api/v1/admin/reports/#{rid}/resolve")
        |> json_response(200)

      assert resolved["action_taken"] == true

      reopened =
        conn
        |> post(~p"/api/v1/admin/reports/#{rid}/reopen")
        |> json_response(200)

      assert reopened["action_taken"] == false
    end
  end

  ## Account actions

  describe "account actions" do
    setup do
      admin = register_admin!()
      target = register_user!(username: "victim", email: "v@example.com")
      %{admin: admin, target: target}
    end

    test "suspend marks the account suspended; unsuspend reverses", ctx do
      conn = auth(build_conn(), ctx.admin.bearer)
      tid = Integer.to_string(ctx.target.profile.id)

      _ =
        conn
        |> post(~p"/api/v1/admin/accounts/#{tid}/action", %{"type" => "suspend"})
        |> json_response(200)

      reloaded = Repo.get!(Profiles.Profile, ctx.target.profile.id)
      assert reloaded.is_suspended == true
      assert reloaded.status == "suspended"

      _ = conn |> post(~p"/api/v1/admin/accounts/#{tid}/unsuspend") |> json_response(200)

      reloaded = Repo.get!(Profiles.Profile, ctx.target.profile.id)
      refute reloaded.is_suspended
      assert reloaded.status == nil
    end

    test "silence + unsilence + disable + enable", ctx do
      conn = auth(build_conn(), ctx.admin.bearer)
      tid = Integer.to_string(ctx.target.profile.id)

      _ = conn |> post(~p"/api/v1/admin/accounts/#{tid}/action", %{"type" => "silence"})
      assert Repo.get!(Profiles.Profile, ctx.target.profile.id).status == "silenced"

      _ = conn |> post(~p"/api/v1/admin/accounts/#{tid}/unsilence")
      assert Repo.get!(Profiles.Profile, ctx.target.profile.id).status == nil

      _ = conn |> post(~p"/api/v1/admin/accounts/#{tid}/action", %{"type" => "disable"})
      assert Repo.get!(Profiles.Profile, ctx.target.profile.id).status == "disabled"

      _ = conn |> post(~p"/api/v1/admin/accounts/#{tid}/enable")
      assert Repo.get!(Profiles.Profile, ctx.target.profile.id).status == nil
    end

    test "DELETE /admin/accounts/:id purges content", ctx do
      conn = auth(build_conn(), ctx.admin.bearer)
      tid = Integer.to_string(ctx.target.profile.id)

      {:ok, _status} =
        Angler.Statuses.create_local(ctx.target.profile, %{
          "status" => "x",
          "visibility" => "public"
        })

      _ = conn |> delete(~p"/api/v1/admin/accounts/#{tid}") |> json_response(200)

      reloaded = Repo.get!(Profiles.Profile, ctx.target.profile.id)
      assert reloaded.is_suspended
      assert reloaded.bio == nil

      assert Repo.aggregate(
               from(s in Angler.Statuses.Status,
                 where: s.profile_id == ^ctx.target.profile.id and is_nil(s.deleted_at)
               ),
               :count
             ) == 0
    end

    test "POST /admin/accounts/:id/action with invalid type → 422", ctx do
      conn = auth(build_conn(), ctx.admin.bearer)
      tid = Integer.to_string(ctx.target.profile.id)

      assert json_response(
               conn |> post(~p"/api/v1/admin/accounts/#{tid}/action", %{"type" => "bogus"}),
               422
             )
    end
  end

  ## Instance domain blocks

  describe "instance domain blocks" do
    test "CRUD round-trip", _ctx do
      admin = register_admin!()
      conn = auth(build_conn(), admin.bearer)

      created =
        conn
        |> post(~p"/api/v1/admin/domain_blocks", %{
          "domain" => "Bad.example",
          "severity" => "suspend",
          "public_comment" => "spam"
        })
        |> json_response(200)

      assert created["domain"] == "bad.example"
      assert created["severity"] == "suspend"

      [in_list] =
        conn |> get(~p"/api/v1/admin/domain_blocks") |> json_response(200)

      assert in_list["id"] == created["id"]

      updated =
        conn
        |> put(~p"/api/v1/admin/domain_blocks/#{created["id"]}", %{"severity" => "silence"})
        |> json_response(200)

      assert updated["severity"] == "silence"

      _ = conn |> delete(~p"/api/v1/admin/domain_blocks/#{created["id"]}") |> json_response(200)
      assert [] = conn |> get(~p"/api/v1/admin/domain_blocks") |> json_response(200)
    end

    test "instance_suspended? returns true for suspended domains", _ctx do
      {:ok, _} =
        Admin.create_instance_domain_block(%{"domain" => "evil.test", "severity" => "suspend"})

      assert Admin.instance_suspended?("evil.test")
      refute Admin.instance_suspended?("good.test")
    end
  end

  ## Email domain blocks

  describe "email domain blocks" do
    test "blocks signup from listed domain", _ctx do
      admin = register_admin!()
      conn = auth(build_conn(), admin.bearer)

      _ =
        conn
        |> post(~p"/api/v1/admin/email_domain_blocks", %{"domain" => "spam.example"})
        |> json_response(200)

      assert {:error, :email_domain_blocked} =
               Accounts.register(%{
                 username: "spammer",
                 email: "x@spam.example",
                 password: "passwordOK1"
               })

      # Ordinary email still works.
      assert {:ok, _} =
               Accounts.register(%{
                 username: "good",
                 email: "y@good.example",
                 password: "passwordOK1"
               })
    end
  end

  ## Announcements admin

  describe "announcements CRUD" do
    test "create + list + update + delete", _ctx do
      admin = register_admin!()
      conn = auth(build_conn(), admin.bearer)

      created =
        conn
        |> post(~p"/api/v1/admin/announcements", %{
          "text" => "Maintenance at 03:00 UTC",
          "published" => true
        })
        |> json_response(200)

      assert created["text"] =~ "Maintenance"
      assert created["published"] == true

      [_] = conn |> get(~p"/api/v1/admin/announcements") |> json_response(200)

      updated =
        conn
        |> put(~p"/api/v1/admin/announcements/#{created["id"]}", %{"text" => "rescheduled"})
        |> json_response(200)

      assert updated["text"] == "rescheduled"

      _ = conn |> delete(~p"/api/v1/admin/announcements/#{created["id"]}") |> json_response(200)
      assert [] = conn |> get(~p"/api/v1/admin/announcements") |> json_response(200)
    end
  end

  ## Federation tie-in

  describe "instance defederation" do
    test "InboxValidator drops activities from defederated domains", _ctx do
      {:ok, _} =
        Admin.create_instance_domain_block(%{
          "domain" => "evil.test",
          "severity" => "suspend"
        })

      args = %{
        "headers" => %{"date" => "Wed, 01 Jan 2026 00:00:00 GMT"},
        "raw_body" => Base.encode64("{}"),
        "payload" => %{"id" => "x", "type" => "Create", "actor" => "https://evil.test/users/bob"},
        "path" => "/users/alice/inbox",
        "recipient_id" => nil
      }

      assert :ok =
               Angler.Federation.Workers.InboxValidator.perform(%Oban.Job{args: args})

      # Rejected federation_activity row was logged.
      assert Repo.exists?(
               from a in Angler.Federation.Activity,
                 where: a.status == :rejected and a.error == "defederated"
             )
    end
  end
end
