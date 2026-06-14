defmodule AnglerWeb.ProfileFollowsTest do
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Follows
  alias Angler.Profiles

  defp local!(username, attrs \\ %{}) do
    {:ok, p} = Profiles.create_profile(Map.merge(%{username: username}, attrs))
    p
  end

  describe "profile page" do
    test "follower/following counts link to the list views", %{conn: conn} do
      local!("alice")
      {:ok, lv, _html} = live(conn, ~p"/@alice")

      assert has_element?(lv, ~s{a[href="/@alice/followers"]})
      assert has_element?(lv, ~s{a[href="/@alice/following"]})
    end
  end

  describe "followers / following lists" do
    test "followers page lists accounts that follow the profile", %{conn: conn} do
      alice = local!("alice")
      bob = local!("bob")
      {:ok, :accepted, _} = Follows.follow(bob, alice)

      {:ok, lv, _html} = live(conn, ~p"/@alice/followers")

      assert has_element?(lv, ".tab-active", "Followers")
      assert has_element?(lv, ~s{a[href="/@bob"]})
    end

    test "following page lists accounts the profile follows", %{conn: conn} do
      alice = local!("alice")
      carol = local!("carol")
      {:ok, :accepted, _} = Follows.follow(alice, carol)

      {:ok, lv, _html} = live(conn, ~p"/@alice/following")

      assert has_element?(lv, ".tab-active", "Following")
      assert has_element?(lv, ~s{a[href="/@carol"]})
    end

    test "empty list shows a friendly message", %{conn: conn} do
      local!("alice")
      {:ok, _lv, html} = live(conn, ~p"/@alice/followers")
      assert html =~ "No followers yet."
    end

    test "private account shows a locked notice instead of the list", %{conn: conn} do
      priv = local!("priv", %{is_private: true})
      fan = local!("fan")
      # A locked account approves a follow request → an accepted follower exists,
      # but the list must still be hidden behind the privacy notice.
      {:ok, :pending, _} = Follows.follow(fan, priv)
      {:ok, _} = Follows.authorize_request(priv, fan)
      assert [_] = Follows.list_followers(priv)

      {:ok, _lv, html} = live(conn, ~p"/@priv/followers")
      assert html =~ "This account is private."
      refute html =~ "/@fan"
    end

    test "unknown user renders not found", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/@nobody/followers")
      assert html =~ "Account not found"
    end
  end
end
