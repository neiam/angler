defmodule Angler.Integration.FederationFollowE2ETest do
  @moduledoc """
  End-to-end: inbound Follow from a remote actor → InboxValidator verifies the
  signature → ActivityHandler dispatches to Follows.Federation → Follower row
  inserted → FollowDeliver POSTs a signed Accept back to the remote inbox.

  All outbound HTTP is intercepted via `Req.Test`. There is no real network.
  """

  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Federation.HTTPSignature
  alias Angler.Follows
  alias Angler.Profiles
  alias Angler.Profiles.Keypair
  alias Angler.Repo

  setup do
    # Set up a local profile (the followee).
    {:ok, alice} = Profiles.create_profile(%{username: "alice"})

    # Generate a remote actor's keypair. We'll have the remote send us a
    # Follow signed by its private key; our actor resolver will fetch the
    # actor doc (containing the public key) when it tries to verify the sig.
    {remote_pub_pem, remote_priv_pem} = Keypair.generate()
    remote_actor_url = "http://remote.test/users/bob"
    remote_inbox_url = "http://remote.test/users/bob/inbox"

    actor_doc = %{
      "@context" => ["https://www.w3.org/ns/activitystreams", "https://w3id.org/security/v1"],
      "id" => remote_actor_url,
      "type" => "Person",
      "preferredUsername" => "bob",
      "name" => "Bob",
      "summary" => "Remote bob",
      "inbox" => remote_inbox_url,
      "outbox" => "http://remote.test/users/bob/outbox",
      "followers" => "http://remote.test/users/bob/followers",
      "following" => "http://remote.test/users/bob/following",
      "publicKey" => %{
        "id" => remote_actor_url <> "#main-key",
        "owner" => remote_actor_url,
        "publicKeyPem" => remote_pub_pem
      }
    }

    # Stub Req: any GET to the remote actor URL returns the actor doc.
    # Any POST to the remote inbox URL captures the request and returns 202.
    test_pid = self()

    Req.Test.stub(:angler_http, fn conn ->
      case conn do
        %Plug.Conn{method: "GET", request_path: "/users/bob"} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/activity+json")
          |> Plug.Conn.send_resp(200, Jason.encode!(actor_doc))

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

    # Allow Oban worker processes to use the stub registered above.
    Req.Test.set_req_test_to_shared(self())

    %{
      alice: alice,
      remote_actor_url: remote_actor_url,
      remote_inbox_url: remote_inbox_url,
      remote_pub_pem: remote_pub_pem,
      remote_priv_pem: remote_priv_pem
    }
  end

  test "signed Follow → Follower row + outbound signed Accept", ctx do
    follow_activity_id = "http://remote.test/activities/follow-1"
    object_actor_url = AnglerWeb.Endpoint.url() <> "/users/alice"

    payload = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => follow_activity_id,
      "type" => "Follow",
      "actor" => ctx.remote_actor_url,
      "object" => object_actor_url
    }

    body = Jason.encode!(payload)
    path = "/users/alice/inbox"
    host = "localhost"
    key_id = ctx.remote_actor_url <> "#main-key"

    {:ok, signed_headers} =
      HTTPSignature.sign(:post, path, host, body, key_id, ctx.remote_priv_pem, [
        {"Content-Type", "application/activity+json"}
      ])

    conn = build_conn() |> Map.put(:host, host)

    conn =
      signed_headers
      # Plug.Conn rejects `Host` set via put_req_header; the conn already
      # carries a :host field which we set above.
      |> Enum.reject(fn {k, _v} -> String.downcase(k) == "host" end)
      |> Enum.reduce(conn, fn {k, v}, c ->
        put_req_header(c, String.downcase(k), v)
      end)

    # Round-trip the request through the endpoint (so RawBodyReader fires).
    conn = Phoenix.ConnTest.dispatch(conn, @endpoint, :post, path, body)
    assert response(conn, 202) == ""

    # InboxValidator was enqueued by the controller. Drain the federation_inbound
    # queue to run validation, dispatch, and the Follow handler — which in turn
    # enqueues FollowDeliver on federation_outbound. Run that too.
    drain = Oban.drain_queue(queue: :federation_inbound, with_recursion: true)

    if drain.failure > 0 do
      jobs =
        Oban.Job
        |> Repo.all()
        |> Enum.map(fn j -> {j.worker, j.state, j.errors} end)

      flunk("inbound drain failed: #{inspect(drain)}\njobs:\n#{inspect(jobs, pretty: true)}")
    end

    assert drain.success >= 1, "expected at least one successful inbound job"

    # Local follower row should now exist.
    bob = Repo.get_by!(Angler.Profiles.Profile, remote_url: ctx.remote_actor_url)
    follower = Follows.get_follower(ctx.alice.id, bob.id)
    assert follower
    assert follower.accepted_at

    # Drain outbound to actually POST the Accept.
    assert %{success: out_s, failure: 0} = Oban.drain_queue(queue: :federation_outbound)
    assert out_s >= 1

    assert_received {:remote_inbox_post, accept_conn, accept_body}

    accept = Jason.decode!(accept_body)
    assert accept["type"] == "Accept"
    assert accept["actor"] == object_actor_url
    assert accept["object"]["id"] == follow_activity_id
    assert accept["object"]["type"] == "Follow"

    # The outbound Accept must be signed with our actor's key. Reconstruct the
    # verification: build a key resolver that returns alice's public key.
    sig_header = get_req_header_str(accept_conn, "signature")
    assert sig_header =~ "keyId=\"#{object_actor_url}#main-key\""

    alice_reloaded = Repo.get!(Angler.Profiles.Profile, ctx.alice.id)
    accept_path = "/users/bob/inbox"

    accept_headers =
      Enum.map(accept_conn.req_headers, fn {k, v} -> {String.downcase(k), v} end)

    resolver = fn _key_id -> {:ok, alice_reloaded.public_key_pem} end

    assert :ok =
             HTTPSignature.verify(:post, accept_path, accept_headers, accept_body, resolver)

    # Inbound Follow → "follow" notification for alice.
    notifications = Repo.all(Angler.Notifications.Notification)

    assert Enum.any?(
             notifications,
             &(&1.type == "follow" and &1.recipient_id == ctx.alice.id and &1.account_id == bob.id)
           )
  end

  defp get_req_header_str(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [v | _] -> v
      _ -> ""
    end
  end
end
