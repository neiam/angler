defmodule AnglerWeb.TintHashtagsTest do
  @moduledoc "The admin \"Tinted hashtags\" switch and the class it puts on the page."
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Instance

  defp admin_conn do
    {:ok, %{user: user}} =
      Accounts.register(%{username: "root", email: "root@example.com", password: "verysecret123"})

    {:ok, user} = Accounts.set_admin(user, true)
    Plug.Test.init_test_session(build_conn(), %{user_id: user.id})
  end

  test "on by default: pages carry tint-tags", %{conn: conn} do
    assert Instance.tint_hashtags?()

    {:ok, lv, _html} = live(conn, ~p"/")
    assert has_element?(lv, "main#main.tint-tags")
  end

  test "an admin can switch it off and back on" do
    conn = admin_conn()
    {:ok, admin, _html} = live(conn, ~p"/admin")
    assert has_element?(admin, "#toggle-tint_hashtags input[checked]")

    admin |> element("#toggle-tint_hashtags input") |> render_click()
    refute Instance.tint_hashtags?()
    refute has_element?(admin, "#toggle-tint_hashtags input[checked]")

    {:ok, lv, _html} = live(build_conn(), ~p"/")
    assert has_element?(lv, "main#main")
    refute has_element?(lv, "main#main.tint-tags")

    admin |> element("#toggle-tint_hashtags input") |> render_click()
    assert Instance.tint_hashtags?()
  end
end
