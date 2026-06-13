defmodule AnglerWeb.WebFrontendTest do
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Statuses

  setup do
    {:ok, %{profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    {:ok, status} = Statuses.create_local(alice, %{"status" => "hello world"})
    %{alice: alice, status: status}
  end

  test "index renders instance stats and the live public feed", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ "Known Network"
    assert html =~ "Posts"
    assert html =~ "hello world"
  end

  test "profile page lists the account's public posts", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/@#{"alice"}")
    assert html =~ "@alice"
    assert html =~ "hello world"
  end

  test "unknown profile renders a not-found state", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/@#{"nobody"}")
    assert html =~ "Account not found"
  end

  test "status permalink renders the single post", %{conn: conn, status: status} do
    {:ok, _lv, html} = live(conn, ~p"/p/#{"alice"}/#{status.id}")
    assert html =~ "hello world"
    assert html =~ "Permalink"
  end

  test "login page renders", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/login")
    assert html =~ "Log in"
  end

  describe "registration gating" do
    test "shows the closed notice when open_registration is off", %{conn: conn} do
      set_open_registration(false)
      {:ok, _lv, html} = live(conn, ~p"/register")
      assert html =~ "Registration is closed"
    end

    test "shows the email step when open_registration is on", %{conn: conn} do
      set_open_registration(true)
      {:ok, _lv, html} = live(conn, ~p"/register")
      assert html =~ "Create an account"
      assert html =~ "Send verification code"
    end
  end

  defp set_open_registration(value) do
    previous = Application.get_env(:angler, :open_registration)
    Application.put_env(:angler, :open_registration, value)
    on_exit(fn -> Application.put_env(:angler, :open_registration, previous) end)
  end
end
