defmodule AnglerWeb.TagsLiveTest do
  use AnglerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Repo
  alias Angler.Statuses
  alias Angler.Statuses.StatusHashtag

  setup do
    {:ok, %{profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    post = fn text, visibility ->
      {:ok, s} =
        Statuses.create_local(alice, %{
          "status" => text,
          "visibility" => visibility,
          "media_ids" => [photo_asset!(alice).id]
        })

      s
    end

    post.("#sunset #film", "public")
    post.("#sunset again", "public")
    old = post.("#archive", "public")
    post.("#secret", "private")

    # Only tag uses on photo posts count: a text post doesn't.
    {:ok, _} = Statuses.create_local(alice, %{"status" => "#textonly", "visibility" => "public"})

    # #archive was used two months ago.
    long_ago = DateTime.add(DateTime.utc_now(), -60 * 86_400)

    Repo.update_all(from(sh in StatusHashtag, where: sh.status_id == ^old.id),
      set: [inserted_at: long_ago]
    )

    :ok
  end

  test "/tags ranks this week's tags by photo posts, public only", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/tags")
    assert has_element?(lv, "#period-week.tab-active")
    assert has_element?(lv, "#top-tags li:first-child#top-tag-sunset")
    assert has_element?(lv, ~s(#top-tag-sunset a[href="/tags/sunset"]))
    assert has_element?(lv, "#top-tag-film")
    refute has_element?(lv, "#top-tag-archive")
    refute has_element?(lv, "#top-tag-secret")
    refute has_element?(lv, "#top-tag-textonly")
  end

  test "period tabs patch to /tags/top/:period", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/tags")

    lv |> element("#period-year") |> render_click()
    assert_patch(lv, ~p"/tags/top/year")
    assert has_element?(lv, "#top-tag-archive")

    lv |> element("#period-today") |> render_click()
    assert_patch(lv, ~p"/tags/top/today")
    refute has_element?(lv, "#top-tag-archive")

    lv |> element("#period-week") |> render_click()
    assert_patch(lv, ~p"/tags")

    {:ok, lv, _} = live(conn, ~p"/tags/top/all")
    assert has_element?(lv, "#period-all.tab-active")
    assert has_element?(lv, "#top-tag-archive")
  end

  test "an unknown period falls back to /tags", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/tags"}}} = live(conn, ~p"/tags/top/decade")
  end

  test "a tag named top keeps its own pages", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/tags/top/mason")
    assert has_element?(lv, "#feed.masonry-feed")
  end
end
