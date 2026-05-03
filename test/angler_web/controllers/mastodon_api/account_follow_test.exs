defmodule AnglerWeb.MastodonAPI.AccountFollowTest do
  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.Follows
  alias Angler.OAuth
  alias Angler.Profiles

  setup do
    {:ok, %{user: user, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: client} = OAuth.first_party_client!()

    {:ok, %{access: write}} = OAuth.issue_token(user, client, scopes: ["write"])
    {:ok, %{access: read}} = OAuth.issue_token(user, client, scopes: ["read"])

    {:ok, bob} = Profiles.create_profile(%{username: "bob"})

    %{alice: alice, bob: bob, write: write, read: read}
  end

  describe "POST /api/v1/accounts/:id/follow" do
    test "401 without bearer", %{conn: conn, bob: bob} do
      conn = post(conn, ~p"/api/v1/accounts/#{Integer.to_string(bob.id)}/follow")
      assert json_response(conn, 401)
    end

    test "200 + Relationship after local follow", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.write)
        |> post(~p"/api/v1/accounts/#{Integer.to_string(ctx.bob.id)}/follow")

      body = json_response(conn, 200)
      assert body["id"] == Integer.to_string(ctx.bob.id)
      assert body["following"] == true
      assert body["requested"] == false
    end

    test "422 on self-follow", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.write)
        |> post(~p"/api/v1/accounts/#{Integer.to_string(ctx.alice.id)}/follow")

      assert json_response(conn, 422)["error"] =~ "yourself"
    end

    test "404 for unknown target", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.write)
        |> post(~p"/api/v1/accounts/999999999/follow")

      assert json_response(conn, 404)
    end

    test "remote target → requested-style state, outbound Follow enqueued", ctx do
      {:ok, remote} =
        Profiles.create_profile(%{
          username: "carol",
          domain: "remote.test",
          remote_url: "http://remote.test/users/carol",
          inbox_url: "http://remote.test/users/carol/inbox",
          public_key_pem: "stub"
        })

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.write)
        |> post(~p"/api/v1/accounts/#{Integer.to_string(remote.id)}/follow")

      body = json_response(conn, 200)
      # Pre-Accept, Mastodon clients see following=false (counter-bumps wait
      # for the inbound Accept). The Follower row is in pending_remote state.
      assert body["following"] == false

      assert_enqueued(
        worker: Angler.Federation.Workers.FollowDeliver,
        args: %{"verb" => "follow"}
      )
    end
  end

  describe "POST /api/v1/accounts/:id/unfollow" do
    test "200 + Relationship after unfollow", ctx do
      Follows.follow(ctx.alice, ctx.bob)

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.write)
        |> post(~p"/api/v1/accounts/#{Integer.to_string(ctx.bob.id)}/unfollow")

      body = json_response(conn, 200)
      assert body["following"] == false
    end

    test "is idempotent (200 even if not following)", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.write)
        |> post(~p"/api/v1/accounts/#{Integer.to_string(ctx.bob.id)}/unfollow")

      assert json_response(conn, 200)
    end
  end

  describe "GET /api/v1/accounts/relationships" do
    test "401 without bearer", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/accounts/relationships?id[]=1")
      assert json_response(conn, 401)
    end

    test "returns one entry per target id in input order", ctx do
      {:ok, carol} = Profiles.create_profile(%{username: "carol"})
      Follows.follow(ctx.alice, ctx.bob)

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.read)
        |> get(
          ~p"/api/v1/accounts/relationships?id[]=#{Integer.to_string(ctx.bob.id)}&id[]=#{Integer.to_string(carol.id)}"
        )

      body = json_response(conn, 200)
      assert length(body) == 2

      [b, c] = body
      assert b["id"] == Integer.to_string(ctx.bob.id)
      assert b["following"] == true
      assert c["id"] == Integer.to_string(carol.id)
      assert c["following"] == false
    end

    test "empty id list → []", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.read)
        |> get(~p"/api/v1/accounts/relationships")

      assert json_response(conn, 200) == []
    end
  end
end
