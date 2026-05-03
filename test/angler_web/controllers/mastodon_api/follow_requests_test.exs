defmodule AnglerWeb.MastodonAPI.FollowRequestsTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.Follows
  alias Angler.OAuth
  alias Angler.Profiles

  setup do
    {:ok, %{user: user, profile: target}} =
      Accounts.register(%{
        username: "locked",
        email: "locked@example.com",
        password: "verysecret123"
      })

    {:ok, target} =
      target
      |> Ecto.Changeset.change(is_private: true)
      |> Angler.Repo.update()

    %{client: client} = OAuth.first_party_client!()
    {:ok, %{access: read}} = OAuth.issue_token(user, client, scopes: ["read"])
    {:ok, %{access: write}} = OAuth.issue_token(user, client, scopes: ["write"])

    {:ok, alice} = Profiles.create_profile(%{username: "alice"})

    %{target: target, alice: alice, read: read, write: write}
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  test "GET /follow_requests returns pending followers", ctx do
    {:ok, :pending, _} = Follows.follow(ctx.alice, ctx.target)

    conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v1/follow_requests")
    [hit] = json_response(conn, 200)
    assert hit["username"] == "alice"
  end

  test "POST /follow_requests/:id/authorize promotes to follower", ctx do
    {:ok, :pending, _} = Follows.follow(ctx.alice, ctx.target)

    conn =
      auth(ctx.conn, ctx.write)
      |> post(~p"/api/v1/follow_requests/#{Integer.to_string(ctx.alice.id)}/authorize")

    rel = json_response(conn, 200)
    assert rel["followed_by"] == true

    # Request gone, follower row exists.
    refute Follows.get_request(ctx.target.id, ctx.alice.id)
    assert Follows.get_follower(ctx.target.id, ctx.alice.id)
  end

  test "POST /follow_requests/:id/reject deletes the request", ctx do
    {:ok, :pending, _} = Follows.follow(ctx.alice, ctx.target)

    conn =
      auth(ctx.conn, ctx.write)
      |> post(~p"/api/v1/follow_requests/#{Integer.to_string(ctx.alice.id)}/reject")

    rel = json_response(conn, 200)
    assert rel["followed_by"] == false

    refute Follows.get_request(ctx.target.id, ctx.alice.id)
    refute Follows.get_follower(ctx.target.id, ctx.alice.id)
  end

  test "401 without bearer", ctx do
    conn = get(ctx.conn, ~p"/api/v1/follow_requests")
    assert json_response(conn, 401)
  end
end
