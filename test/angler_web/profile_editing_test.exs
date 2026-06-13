defmodule AnglerWeb.ProfileEditingTest do
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Accounts.User
  alias Angler.OAuth
  alias Angler.Repo

  setup %{conn: conn} do
    {:ok, %{user: user, profile: profile}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: client} = OAuth.first_party_client!()
    {:ok, %{access: bearer}} = OAuth.issue_token(user, client, scopes: ["read", "write"])

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> bearer),
      user: user,
      profile: profile
    }
  end

  describe "PATCH update_credentials" do
    test "persists profile fields + settings and round-trips via verify_credentials", %{
      conn: conn
    } do
      body =
        conn
        |> patch(~p"/api/v1/accounts/update_credentials?_pe=1", %{
          "display_name" => "Alice A",
          "note" => "hi there",
          "website" => "example.com",
          "location" => "Earth",
          "locked" => "true",
          "crawlable" => "false",
          "public_dm" => "true",
          "show_profile_follower_count" => "false",
          "source" => %{"privacy" => "unlisted", "language" => "fr"}
        })
        |> json_response(200)

      assert body["display_name"] == "Alice A"
      assert body["locked"] == true
      assert body["location"] == "Earth"
      assert body["settings"]["crawlable"] == false
      assert body["settings"]["public_dm"] == true
      assert body["settings"]["show_profile_follower_count"] == false
      assert body["source"]["privacy"] == "unlisted"
      assert body["source"]["language"] == "fr"

      # Round-trip: a fresh verify_credentials reflects the saved settings.
      vc =
        conn |> get(~p"/api/v1/accounts/verify_credentials?_pe=1") |> json_response(200)

      assert vc["settings"]["crawlable"] == false
      assert vc["settings"]["public_dm"] == true
      assert vc["source"]["privacy"] == "unlisted"
      assert vc["source"]["language"] == "fr"
    end

    test "pronouns + location", %{conn: conn} do
      body =
        conn
        |> patch(~p"/api/v1/accounts/update_credentials?_pe=1", %{
          "pronouns" => ["she", "her", ""],
          "location" => "NYC"
        })
        |> json_response(200)

      assert body["pronouns"] == ["she", "her"]
      assert body["location"] == "NYC"
    end
  end

  test "GET /accounts/:id?_pe=1 includes website/location/pronouns (app reads its profile here)",
       %{conn: conn, profile: profile} do
    {:ok, _} =
      profile
      |> Ecto.Changeset.change(
        website: "site.example",
        location: "Earth",
        pronouns: ["they", "them"]
      )
      |> Repo.update()

    body = conn |> get(~p"/api/v1/accounts/#{profile.id}?_pe=1") |> json_response(200)
    assert body["website"] == "site.example"
    assert body["location"] == "Earth"
    assert body["pronouns"] == ["they", "them"]
    # own profile → settings block present
    assert is_map(body["settings"])
  end

  test "DELETE /api/v1.1/accounts/header clears the header", %{conn: conn, profile: profile} do
    Repo.update!(Ecto.Changeset.change(profile, header_path: "uploads/x.jpg"))
    body = conn |> delete(~p"/api/v1.1/accounts/header") |> json_response(200)
    # header falls back to the default (empty string), not the old path
    refute body["header"] == "uploads/x.jpg"
  end

  describe "account management" do
    test "change_email with correct password", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/v1.1/accounts/email", %{
          "current_password" => "verysecret123",
          "email" => "new@example.com"
        })
        |> json_response(200)

      assert body["message"] =~ "Email"
      assert Accounts.get_by_email("new@example.com")
    end

    test "change_email with wrong password → 422", %{conn: conn} do
      assert conn
             |> post(~p"/api/v1.1/accounts/email", %{
               "current_password" => "nope",
               "email" => "x@example.com"
             })
             |> json_response(422)
    end

    test "disable account", %{conn: conn, user: user} do
      assert conn
             |> post(~p"/api/v1.1/accounts/disable", %{"password" => "verysecret123"})
             |> json_response(200)

      assert Repo.get(User, user.id).status == "disabled"
    end

    test "delete account (soft tombstone)", %{conn: conn, user: user} do
      assert conn
             |> post(~p"/api/v1.1/accounts/delete", %{"password" => "verysecret123"})
             |> json_response(200)

      assert Repo.get(User, user.id).status == "delete"
    end

    test "delete account with wrong password → 422", %{conn: conn} do
      assert conn
             |> post(~p"/api/v1.1/accounts/delete", %{"password" => "wrong"})
             |> json_response(422)
    end
  end

  describe "profile-edit LiveView" do
    setup %{user: user} do
      %{authed_conn: Plug.Test.init_test_session(build_conn(), %{user_id: user.id})}
    end

    test "renders the editor for a logged-in user", %{authed_conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/profile")
      assert html =~ "Edit profile"
      assert html =~ "Display name"
      assert html =~ "Private account"
    end

    test "saving updates profile + settings", %{authed_conn: conn, user: user} do
      {:ok, lv, _} = live(conn, ~p"/settings/profile")

      html =
        lv
        |> form("form", %{
          "profile" => %{
            "display_name" => "Alice Web",
            "note" => "edited on web",
            "website" => "alice.example",
            "location" => "Mars",
            "pronouns" => "they, them",
            "locked" => "true",
            "crawlable" => "false",
            "public_dm" => "true"
          }
        })
        |> render_submit()

      assert html =~ "Profile updated."

      profile = Angler.Profiles.get_profile(user.profile_id)
      assert profile.name == "Alice Web"
      assert profile.is_private == true
      assert profile.pronouns == ["they", "them"]

      settings = Angler.Accounts.Settings.account_settings(user.id)
      assert settings["crawlable"] == false
      assert settings["public_dm"] == true
    end

    test "uploading an avatar saves it (no :unreadable)", %{authed_conn: conn, user: user} do
      {:ok, lv, _} = live(conn, ~p"/settings/profile")

      png = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <> :binary.copy(<<0>>, 64)

      avatar =
        file_input(lv, "form", :avatar, [%{name: "a.png", content: png, type: "image/png"}])

      assert render_upload(avatar, "a.png")

      lv |> form("form", %{"profile" => %{"display_name" => "Av"}}) |> render_submit()

      profile = Angler.Profiles.get_profile(user.profile_id)
      assert is_binary(profile.avatar_path) and profile.avatar_path != ""
    end

    test "redirects anonymous users to login", %{conn: _conn} do
      assert {:error, {:live_redirect, %{to: "/login" <> _}}} =
               live(build_conn(), ~p"/settings/profile")
    end
  end
end
