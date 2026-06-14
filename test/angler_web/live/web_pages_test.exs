defmodule AnglerWeb.WebPagesTest do
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Accounts.User
  alias Angler.Repo

  test "index shows the three feed tabs and can switch between them", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/")
    assert html =~ "Local"
    assert html =~ "Known Network"
    assert html =~ "Trending"

    # Switching feeds doesn't crash and updates the empty-state label.
    assert lv |> render_click("switch_feed", %{"feed" => "network"}) =~ "federated posts"
    assert lv |> render_click("switch_feed", %{"feed" => "trending"}) =~ "trending"
    assert lv |> render_click("switch_feed", %{"feed" => "local"}) =~ "local posts"
  end

  test "index links to about + features", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ ~s(href="/about")
    assert html =~ ~s(href="/features")
  end

  test "about page lists admins, rules, and contact", %{conn: conn} do
    {:ok, %{user: user}} =
      Accounts.register(%{
        username: "adminx",
        email: "admin@example.com",
        password: "verysecret123"
      })

    {:ok, _} = user |> Ecto.Changeset.change(is_admin: true) |> Repo.update()

    {:ok, _lv, html} = live(conn, ~p"/about")
    assert html =~ "Administrators"
    assert html =~ "@adminx"
    assert html =~ "Contact"
  end

  test "about page handles no admins gracefully", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/about")
    assert html =~ "No administrators are listed."
  end

  test "about page shows the NEIAM production mark", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/about")
    assert html =~ "ANGLER"
    assert html =~ "production"
    assert html =~ ~s(href="https://neiam.org")
  end

  test "features page renders the feature sections", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/features")
    assert html =~ "Features"
    assert html =~ "Federation"
    assert html =~ "Stories"
    assert html =~ "Pixelfed mobile app"
  end
end
