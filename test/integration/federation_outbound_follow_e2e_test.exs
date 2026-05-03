defmodule Angler.Integration.FederationOutboundFollowE2ETest do
  @moduledoc """
  End-to-end: alice (local) calls POST /accounts/:id/follow against remote
  bob; outbound signed `Follow` activity is delivered; we then simulate the
  inbound `Accept Follow` and verify the relationship flips + counters bump.
  """

  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.Federation.HTTPSignature
  alias Angler.Follows
  alias Angler.Follows.Follower
  alias Angler.OAuth
  alias Angler.Profiles
  alias Angler.Profiles.Keypair
  alias Angler.Profiles.Profile
  alias Angler.Repo

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

    {bob_pub, bob_priv} = Keypair.generate()
    bob_actor_url = "http://remote.test/users/bob"

    {:ok, bob} =
      Profiles.create_profile(%{
        username: "bob",
        domain: "remote.test",
        remote_url: bob_actor_url,
        inbox_url: "http://remote.test/users/bob/inbox",
        public_key_pem: bob_pub
      })

    test_pid = self()

    Req.Test.stub(:angler_http, fn conn ->
      case conn do
        %Plug.Conn{method: "POST", request_path: "/users/bob/inbox"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:remote_inbox_post, conn, body})
          Plug.Conn.send_resp(conn, 202, "")

        other ->
          send(test_pid, {:unexpected_request, other.method, other.request_path})
          Plug.Conn.send_resp(other, 404, "not stubbed")
      end
    end)

    Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})
    on_exit(fn -> Application.delete_env(:angler, :req_options) end)
    Req.Test.set_req_test_to_shared(self())

    %{
      alice: alice,
      bob: bob,
      bob_priv: bob_priv,
      bob_actor_url: bob_actor_url,
      write: write,
      read: read
    }
  end

  test "follow remote → outbound signed Follow → inbound Accept → counters bump", ctx do
    # 1. Local user POSTs follow.
    conn =
      ctx.conn
      |> put_req_header("authorization", "Bearer " <> ctx.write)
      |> post(~p"/api/v1/accounts/#{Integer.to_string(ctx.bob.id)}/follow")

    body = json_response(conn, 200)
    assert body["following"] == false, "pending until Accept"

    # 2. Drain federation_outbound. The signed Follow must reach bob's inbox.
    out = Oban.drain_queue(queue: :federation_outbound)
    assert out.failure == 0

    assert_received {:remote_inbox_post, accept_conn, posted_body}
    activity = Jason.decode!(posted_body)
    assert activity["type"] == "Follow"
    follow_id = activity["id"]
    assert String.starts_with?(follow_id, AnglerWeb.Endpoint.url() <> "/users/alice/follows/")

    # Verify the outbound signature against alice's published key.
    alice_reloaded = Repo.get!(Profile, ctx.alice.id)
    headers_lower = Enum.map(accept_conn.req_headers, fn {k, v} -> {String.downcase(k), v} end)

    assert :ok =
             HTTPSignature.verify(
               :post,
               "/users/bob/inbox",
               headers_lower,
               posted_body,
               fn _ -> {:ok, alice_reloaded.public_key_pem} end
             )

    # 3. Confirm pre-Accept state in DB.
    follower = Repo.get_by!(Follower, profile_id: ctx.bob.id, following_id: ctx.alice.id)
    assert follower.pending_remote == true
    assert is_nil(follower.accepted_at)
    assert Repo.get!(Profile, ctx.bob.id).followers_count == 0

    # 4. Simulate inbound Accept from bob: bob signs an Accept(Follow) and POSTs
    # to alice's inbox. Goes through the real inbox controller → InboxValidator
    # → ActivityHandler → Follows.accept_remote!.
    accept_payload = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => ctx.bob_actor_url <> "/accepts/abc",
      "type" => "Accept",
      "actor" => ctx.bob_actor_url,
      "object" => %{
        "id" => follow_id,
        "type" => "Follow",
        "actor" => AnglerWeb.Endpoint.url() <> "/users/alice",
        "object" => ctx.bob_actor_url
      }
    }

    accept_body = Jason.encode!(accept_payload)
    accept_path = "/users/alice/inbox"

    {:ok, signed_headers} =
      HTTPSignature.sign(
        :post,
        accept_path,
        "localhost",
        accept_body,
        ctx.bob_actor_url <> "#main-key",
        ctx.bob_priv,
        [{"Content-Type", "application/activity+json"}]
      )

    inbox_conn = build_conn() |> Map.put(:host, "localhost")

    inbox_conn =
      signed_headers
      |> Enum.reject(fn {k, _v} -> String.downcase(k) == "host" end)
      |> Enum.reduce(inbox_conn, fn {k, v}, c ->
        put_req_header(c, String.downcase(k), v)
      end)

    inbox_conn = Phoenix.ConnTest.dispatch(inbox_conn, @endpoint, :post, accept_path, accept_body)
    assert response(inbox_conn, 202) == ""

    drain_in = Oban.drain_queue(queue: :federation_inbound, with_recursion: true)

    if drain_in.failure > 0 do
      jobs = Oban.Job |> Repo.all() |> Enum.map(fn j -> {j.worker, j.state, j.errors} end)

      flunk("inbound drain failed: #{inspect(drain_in)}\njobs: #{inspect(jobs, pretty: true)}")
    end

    # 5. Now the relationship should be accepted + counters bumped.
    accepted = Repo.get_by!(Follower, profile_id: ctx.bob.id, following_id: ctx.alice.id)
    refute accepted.pending_remote
    assert accepted.accepted_at

    assert Repo.get!(Profile, ctx.bob.id).followers_count == 1
    assert Repo.get!(Profile, ctx.alice.id).following_count == 1

    # 6. Mastodon Relationship endpoint reflects this.
    rel_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> ctx.read)
      |> get(~p"/api/v1/accounts/relationships?id[]=#{Integer.to_string(ctx.bob.id)}")

    [rel] = json_response(rel_conn, 200)
    assert rel["following"] == true
    assert rel["id"] == Integer.to_string(ctx.bob.id)
  end

  test "unfollow remote → outbound Undo → counter decrements", ctx do
    # Set up alice→bob accepted. The follow itself enqueues a delivery; drain
    # and consume the resulting :remote_inbox_post so it doesn't shadow the
    # Undo we want to assert on.
    {:ok, :pending_remote, follower} = Follows.follow(ctx.alice, ctx.bob)
    Oban.drain_queue(queue: :federation_outbound)
    assert_received {:remote_inbox_post, _conn, _follow_body}

    {:ok, _} = Follows.accept_remote!(follower.remote_url)
    assert Repo.get!(Profile, ctx.bob.id).followers_count == 1

    conn =
      ctx.conn
      |> put_req_header("authorization", "Bearer " <> ctx.write)
      |> post(~p"/api/v1/accounts/#{Integer.to_string(ctx.bob.id)}/unfollow")

    body = json_response(conn, 200)
    assert body["following"] == false

    drain = Oban.drain_queue(queue: :federation_outbound)
    assert drain.failure == 0

    assert_received {:remote_inbox_post, _conn, posted_body}
    activity = Jason.decode!(posted_body)
    assert activity["type"] == "Undo"
    assert activity["object"]["type"] == "Follow"
    assert activity["object"]["id"] == follower.remote_url

    assert Repo.get!(Profile, ctx.bob.id).followers_count == 0
    assert Repo.get!(Profile, ctx.alice.id).following_count == 0
  end
end
