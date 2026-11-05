defmodule AnglerWeb.SitePagesTest do
  @moduledoc "/site/* pages, the app's /e/* links, and their admin editor."

  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.SitePages

  defp admin_conn do
    {:ok, %{user: user}} =
      Accounts.register(%{username: "boss", email: "boss@example.com", password: "verysecret123"},
        approved: true
      )

    {:ok, user} = Accounts.set_admin(user, true)
    Plug.Test.init_test_session(build_conn(), %{user_id: user.id})
  end

  test "every page the app and our federation docs link to renders a default", %{conn: conn} do
    for path <-
          ~w(/e/terms /e/privacy /site/help /site/terms /site/privacy /site/legal-notice
             /site/kb/community-guidelines /site/kb/licenses /site/kb/instance-actor) do
      {:ok, view, _} = live(conn, path)
      assert has_element?(view, "#site-page-body"), path
    end
  end

  test "/site and /site/kb land on an index of every page", %{conn: conn} do
    for path <- ~w(/site /site/kb) do
      {:ok, view, _} = live(conn, path)

      for %{key: key, path: page_path} <- SitePages.list() do
        assert has_element?(view, ~s(#site-link-#{key}[href="#{page_path}"])), key
      end
    end

    {:ok, view, _} = live(conn, ~p"/site/terms")
    assert has_element?(view, ~s(#site-index-link[href="/site"]))
  end

  test "admins write Markdown; it renders without raw HTML; reset restores the default" do
    conn = admin_conn()
    {:ok, view, _} = live(conn, ~p"/admin/pages?page=privacy")

    view
    |> form("#page-form", %{
      "page" => %{
        "title" => "Our privacy policy",
        "content" => "## What we keep\n\nAlmost nothing. <script>alert(1)</script>"
      }
    })
    |> render_submit()

    {:ok, page, _} = live(build_conn(), ~p"/e/privacy")
    assert has_element?(page, "#site-page h1", "Our privacy policy")
    assert has_element?(page, "#site-page-body h2", "What we keep")
    refute render(page) =~ "<script>alert"

    view |> element("#reset-page") |> render_click()
    refute SitePages.get("privacy").custom?
  end

  test "the admin feature switches persist" do
    conn = admin_conn()
    {:ok, view, _} = live(conn, ~p"/admin")
    refute Angler.Stories.enabled?()

    view |> element("#toggle-stories_enabled input") |> render_click()
    assert Angler.Stories.enabled?()
    assert Angler.Instance.get_settings().toggles["stories_enabled"] == true
  end

  test "the about page links the policy pages", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/about")

    for key <- ~w(terms privacy community-guidelines help) do
      assert has_element?(view, "#about-page-#{key}"), key
    end

    # The legal notice only once an admin has written one.
    refute has_element?(view, "#about-page-legal-notice")
    {:ok, _} = SitePages.put("legal-notice", %{"content" => "Operated by someone."})
    {:ok, view, _} = live(conn, ~p"/about")
    assert has_element?(view, "#about-page-legal-notice")
  end
end
