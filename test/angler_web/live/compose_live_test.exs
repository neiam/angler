defmodule AnglerWeb.ComposeLiveTest do
  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  import Phoenix.LiveViewTest

  alias Angler.Accounts

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

  test "anonymous visitors are redirected to login" do
    assert {:error, {:live_redirect, %{to: to}}} = live(build_conn(), ~p"/compose")
    assert to =~ "/login"
  end

  test "renders the composer with the photo editor + license select", ctx do
    {:ok, lv, html} = live(ctx.conn, ~p"/compose")
    assert html =~ "New post"
    assert has_element?(lv, "#photo-editor[phx-hook='PhotoEditor']")
    assert has_element?(lv, "select[name=license]")
    assert has_element?(lv, "textarea[name=caption]")
  end

  test "posting a text-only status creates it and fans out", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/compose")

    {:error, {:live_redirect, %{to: to}}} =
      lv
      |> form("form", %{"caption" => "hello from the web composer", "visibility" => "public"})
      |> render_submit()

    assert to =~ "/p/alice/"

    status = Angler.Statuses.list_for_export(ctx.profile.id) |> List.last()
    assert status.caption == "hello from the web composer"

    assert_enqueued(worker: Angler.Timelines.Workers.FeedInsert)
  end
end
