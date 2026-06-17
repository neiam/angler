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
    {:ok, lv, _html} = live(conn, ~p"/@alice")

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
    {:ok, lv, _html} = live(conn, ~p"/@alice")

    refute has_element?(
             lv,
             ~s{div[id="post-#{pub.id}"] button[phx-click="set_visibility"]}
           )
  end

  test "feed cards carry the deep-link anchor target", %{conn: conn, pub: pub} do
    {:ok, lv, _html} = live(conn, ~p"/@alice")

    # Grid tiles link to `#post-<id>`; the feed card is that scroll target.
    assert has_element?(lv, ~s{#profile-feed div[id="post-#{pub.id}"]})
  end
end
