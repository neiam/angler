defmodule AnglerWeb.QuotesLiveTest do
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Profiles
  alias Angler.Quotes
  alias Angler.Quotes.Authorization
  alias Angler.Repo
  alias Angler.Statuses

  setup do
    {:ok, %{user: user, profile: alice}} =
      Accounts.register(%{username: "alice", email: "alice@example.com", password: "passwordOK1"})

    {:ok, bob} =
      Profiles.create_profile(%{
        username: "bob",
        domain: "remote.test",
        remote_url: "http://remote.test/users/bob",
        inbox_url: "http://remote.test/users/bob/inbox",
        public_key_pem: "stub"
      })

    {:ok, post} = Statuses.create_local(alice, %{"status" => "quote me"}, broadcast: false)
    auth = Quotes.authorize(post, bob, "http://remote.test/notes/q1", nil)

    conn = Plug.Test.init_test_session(build_conn(), %{user_id: user.id})
    %{conn: conn, auth: auth}
  end

  test "lists approvals and revokes one", %{conn: conn, auth: auth} do
    {:ok, lv, _html} = live(conn, ~p"/settings/quotes")
    assert has_element?(lv, "#quote-#{auth.id}")

    lv |> element("#revoke-quote-#{auth.id}") |> render_click()

    refute has_element?(lv, "#quote-#{auth.id}")
    assert has_element?(lv, "#quotes-empty")
    assert %Authorization{state: "revoked"} = Repo.get(Authorization, auth.id)
  end

  test "anonymous visitors are sent to log in" do
    assert {:error, {:live_redirect, %{to: "/login?next=/settings/quotes"}}} =
             live(build_conn(), ~p"/settings/quotes")
  end
end
