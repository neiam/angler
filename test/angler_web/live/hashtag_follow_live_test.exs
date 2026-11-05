defmodule AnglerWeb.HashtagFollowLiveTest do
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Hashtags
  alias Angler.Hashtags.Following

  setup do
    {:ok, %{user: user, profile: profile}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    conn = Plug.Test.init_test_session(build_conn(), %{user_id: user.id})
    %{conn: conn, profile: profile}
  end

  describe "TagLive follow button" do
    test "anonymous visitors see no follow button" do
      {:ok, lv, _html} = live(build_conn(), ~p"/tags/photography")
      refute has_element?(lv, "button[phx-click=follow_tag]")
    end

    test "a logged-in user can follow then unfollow from the tag page", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/tags/photography")

      assert has_element?(lv, "button[phx-click=follow_tag]", "Follow")

      lv |> element("button[phx-click=follow_tag]") |> render_click()

      tag = Hashtags.get_by_name("photography")
      assert Following.following?(ctx.profile.id, tag.id)
      assert has_element?(lv, "button[phx-click=unfollow_tag]", "Following")

      lv |> element("button[phx-click=unfollow_tag]") |> render_click()
      refute Following.following?(ctx.profile.id, tag.id)
      assert has_element?(lv, "button[phx-click=follow_tag]", "Follow")
    end

    test "the button reflects an existing follow on mount", ctx do
      {:ok, _} = Following.follow(ctx.profile, "photography")

      {:ok, lv, _html} = live(ctx.conn, ~p"/tags/photography")
      assert has_element?(lv, "button[phx-click=unfollow_tag]", "Following")
    end
  end

  describe "FollowedTagsLive" do
    test "anonymous visitors are redirected to login" do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(build_conn(), ~p"/settings/followed-tags")

      assert to =~ "/login"
    end

    test "lists followed tags and unfollows them", ctx do
      {:ok, _} = Following.follow(ctx.profile, "art")
      {:ok, _} = Following.follow(ctx.profile, "film")

      {:ok, lv, html} = live(ctx.conn, ~p"/settings/followed-tags")
      assert html =~ "art"
      assert html =~ "film"

      lv |> element("button[phx-value-name=art]") |> render_click()

      refute render(lv) =~ ~r/>#art</
      assert Following.list(ctx.profile.id) |> Enum.map(& &1.name) == ["film"]
    end

    test "shows an empty state when nothing is followed", ctx do
      {:ok, _lv, html} = live(ctx.conn, ~p"/settings/followed-tags")
      assert html =~ "following any hashtags yet"
    end
  end

  describe "TagLive layout toggle" do
    test "switches between list and masonry and is deep-linkable" do
      {:ok, lv, _html} = live(build_conn(), ~p"/tags/photography")
      assert has_element?(lv, "#feed.space-y-3")
      refute has_element?(lv, "#feed.masonry-feed")
      assert has_element?(lv, ~s(#layout-list[aria-pressed="true"]))

      lv |> element("#layout-masonry") |> render_click()
      assert_patch(lv, ~p"/tags/photography?layout=masonry")
      assert has_element?(lv, "#feed.masonry-feed")
      assert has_element?(lv, ~s(#layout-masonry[aria-pressed="true"]))

      lv |> element("#layout-list") |> render_click()
      assert_patch(lv, ~p"/tags/photography")
      assert has_element?(lv, "#feed.space-y-3")

      {:ok, lv, _html} = live(build_conn(), ~p"/tags/photography?layout=masonry")
      assert has_element?(lv, "#feed.masonry-feed")
    end

    test "masonry can hide captions, keeping the choice when switching layouts" do
      {:ok, lv, _html} = live(build_conn(), ~p"/tags/photography")
      refute has_element?(lv, "#captions-toggle")

      {:ok, lv, _html} = live(build_conn(), ~p"/tags/photography?layout=masonry")
      refute has_element?(lv, "#feed.hide-captions")

      lv |> element("#captions-toggle") |> render_click()
      assert_patch(lv, ~p"/tags/photography?captions=off&layout=masonry")
      assert has_element?(lv, "#feed.hide-captions")
      assert has_element?(lv, ~s(#layout-masonry[href*="captions=off"]))

      lv |> element("#layout-list") |> render_click()
      assert_patch(lv, ~p"/tags/photography?captions=off")
      refute has_element?(lv, "#feed.hide-captions")
      refute has_element?(lv, "#captions-toggle")

      lv |> element("#layout-masonry") |> render_click()
      assert_patch(lv, ~p"/tags/photography?captions=off&layout=masonry")
      assert has_element?(lv, "#feed.hide-captions")

      lv |> element("#captions-toggle") |> render_click()
      assert_patch(lv, ~p"/tags/photography?layout=masonry")
      refute has_element?(lv, "#feed.hide-captions")
    end
  end
end
