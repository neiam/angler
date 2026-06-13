defmodule Angler.RegistrationApprovalTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.Auth
  alias Angler.OAuth
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo

  defp with_approval(value) do
    prev = Application.get_env(:angler, :registration_approval_required)
    Application.put_env(:angler, :registration_approval_required, value)
    on_exit(fn -> Application.put_env(:angler, :registration_approval_required, prev) end)
  end

  defp register_pending!(opts \\ []) do
    with_approval(true)

    {:ok, result} =
      Accounts.register(%{
        username: opts[:username] || "pend",
        email: opts[:email] || "pend@example.com",
        password: "verysecret123"
      })

    result
  end

  describe "approval enforcement (context)" do
    test "register creates a pending, unauthenticatable, hidden account" do
      %{user: user} = register_pending!()

      assert user.status == "pending"
      assert Accounts.pending?(user)
      assert Accounts.authenticate("pend", "verysecret123") == :error
      assert Profiles.get_local_by_username("pend") == nil
    end

    test "approve_user activates the account" do
      %{user: user} = register_pending!()

      assert {:ok, approved} = Accounts.approve_user(user)
      assert is_nil(approved.status)
      assert {:ok, _} = Accounts.authenticate("pend", "verysecret123")
      assert %Profile{status: nil} = Profiles.get_local_by_username("pend")
    end

    test "reject_user removes the account" do
      %{user: user, profile: profile} = register_pending!()

      assert :ok = Accounts.reject_user(user)
      assert Accounts.get_by_email("pend@example.com") == nil
      assert Repo.get(Profile, profile.id) == nil
    end

    test "register stays active when approval is not required" do
      {:ok, %{user: user}} =
        Accounts.register(%{
          username: "act",
          email: "act@example.com",
          password: "verysecret123"
        })

      assert is_nil(user.status)
      assert {:ok, _} = Accounts.authenticate("act", "verysecret123")
    end
  end

  describe "enable_user/2 (bootstrap)" do
    test "activates a pending account and grants admin" do
      register_pending!(username: "boot", email: "boot@example.com")

      assert {:ok, user} = Accounts.enable_user("boot", admin: true)
      assert is_nil(user.status)
      assert user.is_admin
      assert {:ok, _} = Accounts.authenticate("boot", "verysecret123")
    end

    test "resolves by email and is status-agnostic (no role granted by default)" do
      register_pending!(username: "boot2", email: "boot2@example.com")

      assert {:ok, user} = Accounts.enable_user("boot2@example.com")
      assert is_nil(user.status)
      refute user.is_admin
    end

    test "unknown handle returns :not_found" do
      assert {:error, :not_found} = Accounts.enable_user("ghost")
    end
  end

  describe "POST /api/auth/onboarding with approval required" do
    test "returns pending and issues no token", %{conn: conn} do
      with_approval(true)
      {:ok, code, _} = Auth.issue_code("newbie@example.com")

      resp =
        post(conn, ~p"/api/auth/onboarding", %{
          "email" => "newbie@example.com",
          "verify_code" => code,
          "username" => "newbie",
          "password" => "verysecret123"
        })

      body = json_response(resp, 202)
      assert body["status"] == "pending"
      refute Map.has_key?(body, "access_token")
      assert Accounts.authenticate("newbie", "verysecret123") == :error
    end
  end

  describe "admin approve/reject endpoints" do
    setup %{conn: conn} do
      {:ok, %{user: admin}} =
        Accounts.register(%{
          username: "mod",
          email: "mod@example.com",
          password: "verysecret123"
        })

      {:ok, admin} = admin |> Ecto.Changeset.change(is_admin: true) |> Repo.update()
      %{client: c} = OAuth.first_party_client!()
      {:ok, %{access: bearer}} = OAuth.issue_token(admin, c, scopes: ["read", "write"])

      %{conn: put_req_header(conn, "authorization", "Bearer " <> bearer)}
    end

    test "approve activates a pending account", %{conn: conn} do
      %{profile: profile} = register_pending!(username: "waiting", email: "waiting@example.com")

      body =
        conn
        |> post(~p"/api/v1/admin/accounts/#{profile.id}/approve")
        |> json_response(200)

      assert body["approved"] == true
      assert {:ok, _} = Accounts.authenticate("waiting", "verysecret123")
    end

    test "reject removes a pending account", %{conn: conn} do
      %{profile: profile} = register_pending!(username: "nope", email: "nope@example.com")

      assert conn |> post(~p"/api/v1/admin/accounts/#{profile.id}/reject") |> json_response(200)
      assert Repo.get(Profile, profile.id) == nil
    end

    test "?pending=true lists pending accounts as unapproved", %{conn: conn} do
      %{profile: profile} = register_pending!(username: "waiting2", email: "waiting2@example.com")

      body =
        conn
        |> get(~p"/api/v1/admin/accounts?pending=true")
        |> json_response(200)

      assert Integer.to_string(profile.id) in Enum.map(body, & &1["id"])
      assert Enum.all?(body, &(&1["approved"] == false))
    end
  end
end
