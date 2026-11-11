defmodule AnglerWeb.ProfileFollowLiveTest do
  @moduledoc "Follow controls on the profile page."
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Follows
  alias Angler.Profiles
  alias Angler.Repo

  setup do
    {:ok, %{user: alice_user, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    {:ok, %{user: bob_user, profile: bob}} =
      Accounts.register(%{username: "bob", email: "bob@example.com", password: "verysecret123"})

    %{
      alice: alice,
      bob: bob,
      alice_conn: Plug.Test.init_test_session(build_conn(), %{user_id: alice_user.id}),
      bob_conn: Plug.Test.init_test_session(build_conn(), %{user_id: bob_user.id})
    }
  end

  test "no button on your own profile", %{alice_conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/@alice")
    refute has_element?(lv, "#follow-button")
  end

  test "anonymous visitors are sent to log in", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/@alice")

    assert {:error, {:live_redirect, %{to: "/login?next=/@alice"}}} =
             lv |> element("#follow-button") |> render_click()
  end

  test "follow, then unfollow", %{bob_conn: conn, alice: alice, bob: bob} do
    {:ok, lv, _html} = live(conn, ~p"/@alice")
    assert has_element?(lv, ~s{#follow-button[phx-click="follow"]}, "Follow")

    lv |> element("#follow-button") |> render_click()
    assert Follows.get_follower(alice.id, bob.id).accepted_at
    assert has_element?(lv, ~s{#follow-button[phx-click="unfollow"]}, "Following")
    assert Profiles.get_profile(alice.id).followers_count == 1

    lv |> element("#follow-button") |> render_click()
    refute Follows.get_follower(alice.id, bob.id)
    assert has_element?(lv, ~s{#follow-button[phx-click="follow"]})
  end

  test "a locked account gets a request, which can be withdrawn", ctx do
    ctx.alice |> Ecto.Changeset.change(is_private: true) |> Repo.update!()

    {:ok, lv, _html} = live(ctx.bob_conn, ~p"/@alice")
    assert has_element?(lv, "#follow-button", "Request to follow")

    lv |> element("#follow-button") |> render_click()
    assert Follows.get_request(ctx.alice.id, ctx.bob.id)
    assert has_element?(lv, "#follow-button", "Requested")

    lv |> element("#follow-button") |> render_click()
    refute Follows.get_request(ctx.alice.id, ctx.bob.id)
  end

  test "shows when the account follows you back", ctx do
    {:ok, :accepted, _} = Follows.follow(ctx.alice, ctx.bob)

    {:ok, lv, _html} = live(ctx.bob_conn, ~p"/@alice")
    assert has_element?(lv, "#follows-you")

    {:ok, lv, _html} = live(ctx.alice_conn, ~p"/@bob")
    refute has_element?(lv, "#follows-you")
  end

  test "a remote account shows Requested until its server accepts", %{bob_conn: conn, bob: bob} do
    {:ok, remote} =
      Profiles.create_profile(%{
        username: "carol",
        domain: "remote.test",
        remote_url: "http://remote.test/users/carol",
        inbox_url: "http://remote.test/users/carol/inbox",
        public_key_pem: "stub"
      })

    {:ok, lv, _html} = live(conn, ~p"/@carol@remote.test")
    lv |> element("#follow-button") |> render_click()

    assert %{accepted_at: nil} = Follows.get_follower(remote.id, bob.id)
    assert has_element?(lv, "#follow-button", "Requested")
  end

  describe "live updates" do
    test "a follow made elsewhere (e.g. the app) updates the open page", ctx do
      {:ok, lv, _html} = live(ctx.bob_conn, ~p"/@alice")
      assert has_element?(lv, ~s{#follow-button[phx-click="follow"]})

      {:ok, :accepted, _} = Follows.follow(ctx.bob, ctx.alice)
      assert has_element?(lv, "#follow-button", "Following")

      :ok = Follows.unfollow(ctx.bob, ctx.alice)
      assert has_element?(lv, ~s{#follow-button[phx-click="follow"]})
    end

    test "an approved request flips Requested to Following", ctx do
      alice = ctx.alice |> Ecto.Changeset.change(is_private: true) |> Repo.update!()

      {:ok, lv, _html} = live(ctx.bob_conn, ~p"/@alice")
      lv |> element("#follow-button") |> render_click()
      assert has_element?(lv, "#follow-button", "Requested")

      {:ok, _} = Follows.authorize_request(alice, ctx.bob)
      assert has_element?(lv, "#follow-button", "Following")
    end

    test "a remote Accept flips Requested to Following", %{bob_conn: conn, bob: bob} do
      {:ok, remote} =
        Profiles.create_profile(%{
          username: "dave",
          domain: "remote.test",
          remote_url: "http://remote.test/users/dave",
          inbox_url: "http://remote.test/users/dave/inbox",
          public_key_pem: "stub"
        })

      {:ok, lv, _html} = live(conn, ~p"/@dave@remote.test")
      lv |> element("#follow-button") |> render_click()
      assert has_element?(lv, "#follow-button", "Requested")

      {:ok, _} = Follows.accept_remote!(Follows.get_follower(remote.id, bob.id).remote_url)
      assert has_element?(lv, "#follow-button", "Following")
    end

    test "being followed back shows Follows you; counts update for any visitor", ctx do
      {:ok, bob_lv, _html} = live(ctx.bob_conn, ~p"/@alice")
      {:ok, anon_lv, _html} = live(build_conn(), ~p"/@alice")
      refute has_element?(bob_lv, "#follows-you")

      {:ok, :accepted, _} = Follows.follow(ctx.alice, ctx.bob)
      assert has_element?(bob_lv, "#follows-you")

      {:ok, :accepted, _} = Follows.follow(ctx.bob, ctx.alice)
      assert render(anon_lv) =~ ~r{>\s*1\s*</span>\s*followers}
    end
  end
end
