defmodule AnglerWeb.WebPagesTest do
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Repo

  test "index shows the three feed tabs and can switch between them", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/")
    assert html =~ "Local"
    assert html =~ "Known Network"
    assert html =~ "Trending"

    # Tabs patch the URL, and each feed's empty-state label follows.
    assert lv |> element("#feed-tab-network") |> render_click() =~ "federated posts"
    assert_patch(lv, ~p"/network")
    assert lv |> element("#feed-tab-trending") |> render_click() =~ "trending"
    assert_patch(lv, ~p"/trending")
    assert lv |> element("#feed-tab-local") |> render_click() =~ "local posts"
    assert_patch(lv, ~p"/")
  end

  test "feeds are deep-linkable", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/network")
    assert has_element?(lv, "#feed-tab-network.tab-active")

    {:ok, lv, _} = live(conn, ~p"/trending")
    assert has_element?(lv, "#feed-tab-trending.tab-active")
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

  test "about page 'Run your own' defaults to podman + ghcr", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/about")
    assert html =~ "Run your own"
    assert html =~ "Get started in 30 seconds"
    assert html =~ "podman run -d --name angler"
    assert html =~ "ghcr.io/neiam/angler:latest"
    # default host + placeholder creds flow into the command
    assert html =~ "PHX_HOST=angler.you.com"
    assert html =~ "ecto://USER:PASS@HOST/angler"
    assert html =~ "repo documentation"
  end

  test "about page interpolates typed user/pass/host into both commands", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/about")

    html =
      lv
      |> form("#run-config", %{"user" => "bob", "pass" => "s3cret", "host" => "pics.example.org"})
      |> render_change()

    assert html =~ "PHX_HOST=pics.example.org"
    assert html =~ "ecto://bob:s3cret@HOST/angler"
    assert html =~ "POSTGRES_USER=bob"
    assert html =~ "POSTGRES_PASSWORD=s3cret"

    # blanking a field falls back to its placeholder default
    html =
      lv
      |> form("#run-config", %{"user" => "", "pass" => "", "host" => ""})
      |> render_change()

    assert html =~ "PHX_HOST=angler.you.com"
    assert html =~ "ecto://USER:PASS@HOST/angler"
  end

  test "about page has a database setup command matching the runtime", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/about")
    assert html =~ "Start your database"
    assert html =~ "podman run -d --name angler-db"
    assert html =~ "docker.io/postgres:16-alpine"

    html =
      lv
      |> element(~s{button[phx-value-runtime="docker"]})
      |> render_click()

    assert html =~ "docker run -d --name angler-db"
  end

  test "about page run-command matrix switches runtime and registry", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/about")

    html =
      lv
      |> element(~s{button[phx-value-runtime="docker"]})
      |> render_click()

    assert html =~ "docker run -d --name angler"

    html =
      lv
      |> element(~s{button[phx-value-registry="quay"]})
      |> render_click()

    assert html =~ "docker run -d --name angler"
    assert html =~ "quay.io/neiam/angler:latest"
    refute html =~ "ghcr.io/neiam/angler:latest"
  end

  test "features page renders the feature sections", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/features")
    assert html =~ "Features"
    assert html =~ "Federation"
    assert html =~ "Stories"
    assert html =~ "Pixelfed mobile app"
  end
end
