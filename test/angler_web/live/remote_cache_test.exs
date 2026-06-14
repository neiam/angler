defmodule AnglerWeb.RemoteCacheTest do
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Profiles
  alias Angler.Statuses

  setup do
    {:ok, bob} =
      Profiles.create_profile(%{
        username: "bob",
        domain: "remote.test",
        remote_url: "https://remote.test/users/bob",
        name: "Bob Remote"
      })

    %{bob: bob, acct: "bob@remote.test"}
  end

  test "remote profile resolves to a cached page with a view-original link", ctx do
    {:ok, _lv, html} = live(ctx.conn, ~p"/@#{ctx.acct}")

    assert html =~ "Bob Remote"
    assert html =~ "View original on remote.test"
    assert html =~ ~s(href="https://remote.test/users/bob")
  end

  test "remote profile counts are not linked to local follow lists", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/@#{ctx.acct}")
    refute has_element?(lv, ~s{a[href$="/followers"]})
    refute has_element?(lv, ~s{a[href$="/following"]})
  end

  test "remote status permalink renders the cached post with a view-original link", ctx do
    {:ok, status} =
      Statuses.create_remote(%{
        profile_id: ctx.bob.id,
        visibility: :public,
        caption: "hello from afar",
        rendered: "<p>hello from afar</p>",
        type: "text",
        local: false,
        uri: "https://remote.test/notes/1"
      })

    {:ok, _lv, html} = live(ctx.conn, ~p"/p/#{ctx.bob.username}/#{status.id}")

    assert html =~ "hello from afar"
    assert html =~ "View original"
  end
end
