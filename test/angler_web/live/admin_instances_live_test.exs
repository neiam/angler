defmodule AnglerWeb.AdminInstancesLiveTest do
  use AnglerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Federation.Instance
  alias Angler.Follows.Follower
  alias Angler.Profiles
  alias Angler.Repo

  defp admin do
    {:ok, %{user: user}} =
      Accounts.register(%{username: "mod", email: "mod@example.com", password: "verysecret123"})

    {:ok, user} = user |> Ecto.Changeset.change(is_admin: true) |> Repo.update()
    user
  end

  defp conn_for(user), do: Plug.Test.init_test_session(build_conn(), %{user_id: user.id})

  defp remote!(username, host) do
    {:ok, p} =
      Profiles.create_profile(%{
        username: username,
        domain: host,
        remote_url: "http://#{host}/users/#{username}",
        inbox_url: "http://#{host}/users/#{username}/inbox",
        public_key_pem: "stub"
      })

    p
  end

  test "non-admins are redirected" do
    {:ok, %{user: user}} =
      Accounts.register(%{username: "reg", email: "reg@example.com", password: "verysecret123"})

    assert {:error, {:redirect, %{to: "/"}}} = live(conn_for(user), ~p"/admin/instances")
  end

  test "lists known servers with their local footprint" do
    user = admin()
    a = Repo.insert!(%Instance{domain: "alpha.test"})
    b = Repo.insert!(%Instance{domain: "beta.test", banned: true, delivery_failures: 3})

    alice = remote!("alice", "alpha.test")
    _ = remote!("bob", "alpha.test")

    Repo.insert!(%Follower{
      profile_id: alice.id,
      following_id: user.profile_id,
      accepted_at: DateTime.utc_now()
    })

    {:ok, lv, _html} = live(conn_for(user), ~p"/admin/instances")

    assert has_element?(lv, "#instance-#{a.id}", "alpha.test")
    assert has_element?(lv, "#instance-#{b.id}", "beta.test")
    assert has_element?(lv, "#instance-#{b.id} .badge", "banned")
    assert has_element?(lv, "#instances-filter-banned", "1")

    %{rows: rows} = Angler.Federation.Instances.list(%{"sort" => "accounts"})
    assert [%{instance: %{domain: "alpha.test"}, accounts: 2, followed_by_local: 1} | _] = rows
  end

  test "filters and searches" do
    user = admin()
    a = Repo.insert!(%Instance{domain: "alpha.test"})
    b = Repo.insert!(%Instance{domain: "beta.test", banned: true})

    {:ok, lv, _html} = live(conn_for(user), ~p"/admin/instances")

    lv |> element("#instances-filter-banned") |> render_click()
    assert has_element?(lv, "#instance-#{b.id}")
    refute has_element?(lv, "#instance-#{a.id}")

    {:ok, lv, _html} = live(conn_for(user), ~p"/admin/instances")
    lv |> form("#instances-search", search: %{q: "alp"}) |> render_change()
    assert has_element?(lv, "#instance-#{a.id}")
    refute has_element?(lv, "#instance-#{b.id}")
  end
end
