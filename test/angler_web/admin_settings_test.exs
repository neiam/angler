defmodule AnglerWeb.AdminSettingsTest do
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Accounts.User
  alias Angler.Instance
  alias Angler.Repo

  defp register!(username, email) do
    {:ok, %{user: user}} =
      Accounts.register(%{username: username, email: email, password: "verysecret123"})

    user
  end

  defp admin_conn do
    user = register!("boss", "boss@example.com")
    {:ok, user} = Accounts.set_admin(user, true)
    {Plug.Test.init_test_session(build_conn(), %{user_id: user.id}), user}
  end

  describe "Instance.update_settings" do
    test "DB override beats env, and a blank clears it" do
      {:ok, _} =
        Instance.update_settings(%{
          "title" => "My Server",
          "contact_email" => "ops@example.com",
          "rules" => ["Be nice", "No spam"]
        })

      assert Instance.title() == "My Server"
      assert Instance.contact_email() == "ops@example.com"
      assert Instance.rules() == ["Be nice", "No spam"]

      {:ok, _} = Instance.update_settings(%{"contact_email" => ""})
      assert is_nil(Instance.contact_email())
    end

    test "rejects an invalid contact email" do
      assert {:error, _} = Instance.update_settings(%{"contact_email" => "not-an-email"})
    end
  end

  describe "set_admin_by_handle" do
    test "grants and revokes by username or email" do
      user = register!("u1", "u1@example.com")
      refute Repo.get(User, user.id).is_admin

      assert {:ok, _} = Accounts.set_admin_by_handle("u1", true)
      assert Repo.get(User, user.id).is_admin

      assert {:ok, _} = Accounts.set_admin_by_handle("u1@example.com", false)
      refute Repo.get(User, user.id).is_admin

      assert {:error, :not_found} = Accounts.set_admin_by_handle("ghost", true)
    end
  end

  describe "admin LiveView gate" do
    test "non-admin is bounced home", %{conn: _} do
      user = register!("plain", "plain@example.com")
      conn = Plug.Test.init_test_session(build_conn(), %{user_id: user.id})
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")
    end

    test "anonymous is sent to login" do
      assert {:error, {:redirect, %{to: "/login" <> _}}} = live(build_conn(), ~p"/admin")
    end
  end

  describe "admin LiveView actions" do
    test "saves instance settings and promotes/demotes admins" do
      {conn, _admin} = admin_conn()
      {:ok, lv, html} = live(conn, ~p"/admin")
      assert html =~ "Admin settings"

      lv
      |> form("form[phx-submit=save_settings]", %{
        "settings" => %{
          "title" => "Cool Server",
          "rules" => "R1\nR2",
          "contact_email" => "c@example.com"
        }
      })
      |> render_submit()

      assert Instance.title() == "Cool Server"
      assert Instance.rules() == ["R1", "R2"]
      assert Instance.contact_email() == "c@example.com"

      target = register!("target", "target@example.com")

      lv
      |> form("form[phx-submit=promote]", %{"username" => "target"})
      |> render_submit()

      assert Repo.get(User, target.id).is_admin

      html = lv |> element("button[phx-value-username=target]") |> render_click()
      refute Repo.get(User, target.id).is_admin
      assert html =~ "Removed admin"
    end
  end
end
