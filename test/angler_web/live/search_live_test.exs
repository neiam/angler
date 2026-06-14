defmodule AnglerWeb.SearchLiveTest do
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Hashtags
  alias Angler.Statuses

  setup do
    {:ok, %{profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    {:ok, _status} = Statuses.create_local(alice, %{"status" => "searchable haystack post"})
    Hashtags.ensure!("haystack")
    %{alice: alice}
  end

  test "empty search shows the landing prompt", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/search")
    assert html =~ "Start typing to search"
  end

  test "query param surfaces accounts, hashtags, and posts", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/search?q=haystack")
    assert html =~ "haystack"
    assert html =~ "searchable haystack post"
  end

  test "account query links to the profile", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/search?q=alice")
    assert has_element?(lv, ~s{a[href="/@alice"]})
  end

  test "typing pushes a patch and runs the search", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/search")

    html =
      lv
      |> form("#search-form", %{"q" => "haystack"})
      |> render_change()

    assert html =~ "searchable haystack post"
    assert_patched(lv, ~p"/search?#{%{q: "haystack", type: "all"}}")
  end

  test "tab switches filter the visible buckets", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/search?q=haystack")

    html =
      lv
      |> element(~s{a[role="tab"]}, "People")
      |> render_click()

    # On the People tab the matching post caption should no longer render.
    refute html =~ "searchable haystack post"
  end

  test "unknown query renders the no-results state", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/search?q=zzzznotfound")
    assert html =~ "No results"
  end
end
