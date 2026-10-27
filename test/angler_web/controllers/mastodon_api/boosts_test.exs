defmodule AnglerWeb.MastodonAPI.BoostsTest do
  @moduledoc "Boosts in the home timeline and on profiles."

  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.{Accounts, Follows, OAuth, Statuses}

  setup do
    [alice, bob, carol] =
      for name <- ~w(alice bob carol) do
        {:ok, %{user: u, profile: p}} =
          Accounts.register(%{
            username: name,
            email: "#{name}@example.com",
            password: "passwordOK1"
          })

        %{client: c} = OAuth.first_party_client!()
        {:ok, %{access: t}} = OAuth.issue_token(u, c, scopes: ["read", "write"])
        %{profile: p, user: u, token: t}
      end

    # carol follows alice; alice boosts bob's post, which carol hasn't seen.
    {:ok, :accepted, _} = Follows.follow(carol.profile, alice.profile)

    {:ok, post} =
      Statuses.create_local(bob.profile, %{"status" => "bob's photo"}, broadcast: false)

    {:ok, _} = Statuses.reblog(alice.profile, post)
    Oban.drain_queue(queue: :feed)

    %{alice: alice, bob: bob, carol: carol, post: post}
  end

  defp get_as(conn, who, path, params \\ %{}) do
    conn
    |> put_req_header("authorization", "Bearer " <> who.token)
    |> get(path, params)
    |> json_response(200)
  end

  test "Mastodon clients get the boost as a wrapper by the booster", %{conn: conn} = ctx do
    assert [wrapper] = get_as(conn, ctx.carol, ~p"/api/v1/timelines/home")

    assert wrapper["account"]["username"] == "alice"
    assert wrapper["reblog"]["id"] == Integer.to_string(ctx.post.id)
    assert wrapper["reblog"]["account"]["username"] == "bob"
    assert wrapper["content"] == ""
  end

  test "the Pixelfed app gets the post itself with reblogged_by, when boosts are on",
       %{conn: conn} = ctx do
    # Off by default for the app, as upstream.
    assert get_as(conn, ctx.carol, ~p"/api/v1/timelines/home", %{"_pe" => "1"}) == []

    {:ok, _} = Angler.Accounts.Settings.set_web_field(ctx.carol.user.id, "enable_reblogs", true)

    assert [post] = get_as(conn, ctx.carol, ~p"/api/v1/timelines/home", %{"_pe" => "1"})
    assert post["id"] == Integer.to_string(ctx.post.id)
    assert post["reblogged_by"]["username"] == "alice"

    # An explicit param wins over the setting.
    assert get_as(conn, ctx.carol, ~p"/api/v1/timelines/home", %{
             "_pe" => "1",
             "include_reblogs" => "false"
           }) == []
  end

  test "boosts by someone you mute are left out", %{conn: conn} = ctx do
    {:ok, _} = Angler.Profiles.BlocksMutes.mute(ctx.carol.profile, ctx.alice.profile)
    assert get_as(conn, ctx.carol, ~p"/api/v1/timelines/home") == []
  end

  test "profiles: Mastodon clients see boosts among posts; the app only with only_reposts",
       %{conn: conn} = ctx do
    {:ok, own} = Statuses.create_local(ctx.alice.profile, %{"status" => "mine"}, broadcast: false)
    path = ~p"/api/v1/accounts/#{Integer.to_string(ctx.alice.profile.id)}/statuses"

    [newest, boost] = get_as(conn, ctx.carol, path)
    assert newest["id"] == Integer.to_string(own.id)
    assert boost["reblog"]["id"] == Integer.to_string(ctx.post.id)

    assert [%{"id" => only}] = get_as(conn, ctx.carol, path, %{"exclude_reblogs" => "true"})
    assert only == Integer.to_string(own.id)

    assert [%{"id" => grid}] = get_as(conn, ctx.carol, path, %{"_pe" => "1"})
    assert grid == Integer.to_string(own.id)

    assert [%{"reblogged_by" => %{"username" => "alice"}}] =
             get_as(conn, ctx.carol, path, %{"_pe" => "1", "only_reposts" => "true"})
  end

  test "unboosting removes it from the feed", %{conn: conn} = ctx do
    {:ok, _} = Statuses.unreblog(ctx.alice.profile, ctx.post)
    assert get_as(conn, ctx.carol, ~p"/api/v1/timelines/home") == []
  end
end
