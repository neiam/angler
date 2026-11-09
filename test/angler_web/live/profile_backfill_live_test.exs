defmodule AnglerWeb.ProfileBackfillLiveTest do
  use AnglerWeb.ConnCase, async: true
  use Oban.Testing, repo: Angler.Repo

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Federation.Workers.Backfill
  alias Angler.Profiles
  alias Angler.Repo

  setup do
    {:ok, alice} =
      Profiles.create_profile(%{
        username: "alice",
        domain: "remote.test",
        remote_url: "http://remote.test/users/alice",
        inbox_url: "http://remote.test/users/alice/inbox",
        public_key_pem: "stub"
      })

    %{alice: alice}
  end

  defp conn_for(username, admin?) do
    {:ok, %{user: user}} =
      Accounts.register(%{
        username: username,
        email: "#{username}@example.com",
        password: "verysecret123"
      })

    {:ok, user} = user |> Ecto.Changeset.change(is_admin: admin?) |> Repo.update()
    Plug.Test.init_test_session(build_conn(), %{user_id: user.id})
  end

  test "non-admins don't get the button" do
    {:ok, lv, _html} = live(conn_for("reg", false), "/@alice@remote.test")
    refute has_element?(lv, "#backfill-posts")
  end

  test "admins don't get it on local profiles" do
    {:ok, lv, _html} = live(conn_for("mod", true), "/@mod")
    refute has_element?(lv, "#backfill-posts")
  end

  test "an admin can queue a backfill and sees the result", %{alice: alice} do
    {:ok, lv, _html} = live(conn_for("mod", true), "/@alice@remote.test")

    lv |> element("#backfill-posts") |> render_click()
    assert_enqueued(worker: Backfill, args: %{"profile_id" => alice.id})
    assert has_element?(lv, "#backfill-posts[disabled]")

    send(lv.pid, {:backfill_done, {:ok, %{imported: 3, existing: 1, skipped: 0, failed: 0}}})
    assert render(lv) =~ "Imported 3 older posts"
    refute has_element?(lv, "#backfill-posts[disabled]")
  end
end
