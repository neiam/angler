defmodule AnglerWeb.IndexMineFeedTest do
  @moduledoc "The landing page's Mine tab: the viewer's home timeline."
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Accounts.Settings
  alias Angler.Likes.Like
  alias Angler.Reblogs.Reblog
  alias Angler.Repo
  alias Angler.Statuses
  alias Angler.Timelines.HomeFeedEntry

  setup do
    {:ok, %{profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    {:ok, %{profile: carol}} =
      Accounts.register(%{
        username: "carol",
        email: "carol@example.com",
        password: "verysecret123"
      })

    {:ok, %{user: bob_user, profile: bob}} =
      Accounts.register(%{username: "bob", email: "bob@example.com", password: "verysecret123"})

    conn = Plug.Test.init_test_session(build_conn(), %{user_id: bob_user.id})
    %{conn: conn, alice: alice, carol: carol, bob: bob, bob_user: bob_user}
  end

  defp photo!(profile, text) do
    {:ok, status} = Statuses.create_local(profile, %{"status" => text})
    {:ok, status} = status |> Ecto.Changeset.change(type: "photo") |> Repo.update()
    status
  end

  defp feed!(profile, status, reblog_id \\ nil) do
    Repo.insert!(%HomeFeedEntry{
      profile_id: profile.id,
      status_id: status.id,
      reblog_id: reblog_id
    })
  end

  test "anonymous visitors get no Mine tab, and /mine sends them to log in" do
    {:ok, lv, _html} = live(build_conn(), ~p"/")
    refute has_element?(lv, "#feed-tab-mine")

    assert {:error, {:live_redirect, %{to: "/login?next=/mine"}}} =
             live(build_conn(), ~p"/mine")
  end

  test "shows the viewer's home timeline", %{conn: conn, alice: alice, bob: bob} do
    followed = photo!(alice, "from someone bob follows")
    feed!(bob, followed)
    _not_in_feed = photo!(alice, "never fanned to bob")

    {:ok, lv, _html} = live(conn, ~p"/")
    assert has_element?(lv, "#feed-tab-mine")

    {:ok, lv, _html} = live(conn, ~p"/mine")
    assert has_element?(lv, ~s{#feed-tab-mine[aria-selected="true"]})
    assert has_element?(lv, "#post-#{followed.id}")
    assert render(lv) =~ "from someone bob follows"
    refute render(lv) =~ "never fanned to bob"
  end

  test "boosts render as the boosted post under a boosted-by line, when enabled", ctx do
    post = photo!(ctx.alice, "boosted photo")
    {:ok, _} = Statuses.reblog(ctx.carol, post)
    reblog = Repo.get_by!(Reblog, profile_id: ctx.carol.id, status_id: post.id)
    feed!(ctx.bob, post, reblog.id)
    {:ok, _} = Settings.set_web_field(ctx.bob_user.id, "enable_reblogs", true)

    {:ok, lv, _html} = live(ctx.conn, ~p"/mine")

    wrapper = "#post-#{reblog.reblog_status_id}"
    assert has_element?(lv, wrapper, "boosted")
    assert has_element?(lv, wrapper, "boosted photo")

    # Acting on the card hits the boosted post and keeps the boost wrapper.
    lv
    |> element("#{wrapper} button[phx-click=favourite][phx-value-id='#{post.id}']")
    |> render_click()

    assert Repo.get_by(Like, profile_id: ctx.bob.id, status_id: post.id)
    assert has_element?(lv, wrapper, "boosted")
    refute has_element?(lv, "#post-#{post.id}")
  end

  test "load more pages through older entries", %{conn: conn, alice: alice, bob: bob} do
    posts = for n <- 1..31, do: photo!(alice, "post #{n}")
    Enum.each(posts, &feed!(bob, &1))
    [oldest | _] = posts

    {:ok, lv, _html} = live(conn, ~p"/mine")
    refute has_element?(lv, "#post-#{oldest.id}")

    lv |> element("#feed-load-more") |> render_click()
    assert has_element?(lv, "#post-#{oldest.id}")
  end
end
