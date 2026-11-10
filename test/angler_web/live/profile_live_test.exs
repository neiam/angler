defmodule AnglerWeb.ProfileLiveTest do
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Statuses

  setup do
    {:ok, %{user: alice_user, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    {:ok, pub} =
      Statuses.create_local(alice, %{"status" => "public hello", "visibility" => "public"})

    {:ok, unlisted} =
      Statuses.create_local(alice, %{"status" => "secret import", "visibility" => "unlisted"})

    owner_conn = Plug.Test.init_test_session(build_conn(), %{user_id: alice_user.id})

    %{alice: alice, pub: pub, unlisted: unlisted, owner_conn: owner_conn}
  end

  test "anonymous visitors see public posts only and no filter tabs", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/@alice")

    assert html =~ "public hello"
    refute html =~ "secret import"
    refute has_element?(lv, "#profile-filter-tabs")
  end

  test "the owner sees filter tabs and their unlisted posts", %{owner_conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/@alice")

    assert has_element?(lv, "#profile-filter-tabs")
    assert html =~ "public hello"
    assert html =~ "secret import"
  end

  test "the owner can filter down to unlisted only", %{owner_conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/@alice")

    html = lv |> element("#profile-filter-tabs button", "Unlisted") |> render_click()

    assert html =~ "secret import"
    refute html =~ "public hello"
  end

  test "the owner can lift a post out of unlisted", %{owner_conn: conn, unlisted: unlisted} do
    {:ok, lv, _html} = live(conn, ~p"/@alice/feed")

    lv
    |> element(
      ~s{div[id="post-#{unlisted.id}"] button[phx-click="set_visibility"][phx-value-visibility="public"]}
    )
    |> render_click()

    assert Statuses.get(unlisted.id).visibility == :public
  end

  test "a visitor cannot change visibility (no owner controls rendered)", %{
    conn: conn,
    pub: pub
  } do
    {:ok, lv, _html} = live(conn, ~p"/@alice/feed")

    refute has_element?(
             lv,
             ~s{div[id="post-#{pub.id}"] button[phx-click="set_visibility"]}
           )
  end

  describe "layouts" do
    test "the grid is the default; its tiles link to the post page", %{conn: conn, pub: pub} do
      {:ok, lv, _html} = live(conn, ~p"/@alice")

      assert has_element?(lv, ~s{#profile-grid a#tile-#{pub.id}[href="/p/alice/#{pub.id}"]})
      assert has_element?(lv, ~s{#layout-grid[aria-pressed="true"]})
      # Grid xor feed: no stacked cards alongside it.
      refute has_element?(lv, "#profile-feed")
      refute has_element?(lv, "#profile-masonry")
    end

    test "/feed shows only the stacked cards", %{conn: conn, pub: pub} do
      {:ok, lv, _html} = live(conn, ~p"/@alice/feed")

      assert has_element?(lv, ~s{#profile-feed div[id="post-#{pub.id}"] article})
      assert has_element?(lv, ~s{#layout-list[aria-pressed="true"]})
      refute has_element?(lv, "#profile-grid")
    end

    test "masonry renders the wall, and clean hides captions", %{conn: conn, pub: pub} do
      {:ok, lv, _html} = live(conn, ~p"/@alice/mason")

      assert has_element?(lv, ~s{#profile-masonry article[id="post-#{pub.id}"]})
      refute has_element?(lv, "#profile-masonry.hide-captions")
      assert has_element?(lv, ~s{#captions-toggle[href="/@alice/mason/clean"]})

      {:ok, lv, _html} = live(conn, ~p"/@alice/mason/clean")
      assert has_element?(lv, "#profile-masonry.hide-captions")
      assert has_element?(lv, ~s{#layout-masonry[aria-pressed="true"]})
    end

    test "the toggle patches between layouts, keeping the loaded posts", %{conn: conn, pub: pub} do
      {:ok, lv, _html} = live(conn, ~p"/@alice")

      lv |> element("#layout-list") |> render_click()
      assert_patch(lv, ~p"/@alice/feed")
      assert has_element?(lv, ~s{#profile-feed div[id="post-#{pub.id}"]})

      lv |> element("#layout-masonry") |> render_click()
      assert_patch(lv, ~p"/@alice/mason")
      assert has_element?(lv, "#profile-masonry")
    end
  end
end
