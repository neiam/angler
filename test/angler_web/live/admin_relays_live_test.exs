defmodule AnglerWeb.AdminRelaysLiveTest do
  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Federation.Relays
  alias Angler.Federation.Workers.RelayDeliver
  alias Angler.Repo

  defp admin_conn do
    {:ok, %{user: user}} =
      Accounts.register(%{username: "mod", email: "mod@example.com", password: "verysecret123"})

    {:ok, user} = user |> Ecto.Changeset.change(is_admin: true) |> Repo.update()
    Plug.Test.init_test_session(build_conn(), %{user_id: user.id})
  end

  defp stub_relay_actor do
    Req.Test.stub(:angler_http, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/activity+json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "id" => "http://relay.test/actor",
          "type" => "Application",
          "inbox" => "http://relay.test/inbox"
        })
      )
    end)

    Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})
    on_exit(fn -> Application.delete_env(:angler, :req_options) end)
    Req.Test.set_req_test_to_shared(self())
  end

  test "non-admins are redirected" do
    {:ok, %{user: user}} =
      Accounts.register(%{username: "reg", email: "reg@example.com", password: "verysecret123"})

    conn = Plug.Test.init_test_session(build_conn(), %{user_id: user.id})
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/relays")
  end

  test "an admin can add a relay" do
    stub_relay_actor()
    {:ok, lv, _html} = live(admin_conn(), ~p"/admin/relays")

    lv
    |> form("form", %{"relay" => %{"actor_url" => "http://relay.test/actor"}})
    |> render_submit()

    assert render(lv) =~ "http://relay.test/actor"
    assert Enum.map(Relays.list(), & &1.actor_url) == ["http://relay.test/actor"]
    assert_enqueued(worker: RelayDeliver, args: %{"verb" => "follow"})
  end
end
