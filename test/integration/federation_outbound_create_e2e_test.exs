defmodule Angler.Integration.FederationOutboundCreateE2ETest do
  @moduledoc """
  End-to-end: alice (local) has a remote follower bob; alice POSTs a new
  status; the outbound `Create Note` should be signed and delivered to bob's
  inbox. We intercept via Req.Test and verify the signature against alice's
  published public key.
  """

  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  import Ecto.Query

  alias Angler.Accounts
  alias Angler.Federation.HTTPSignature
  alias Angler.Follows.Follower
  alias Angler.OAuth
  alias Angler.Profiles
  alias Angler.Repo

  setup do
    {:ok, %{user: user, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: client} = OAuth.first_party_client!()
    {:ok, %{access: bearer}} = OAuth.issue_token(user, client, scopes: ["write"])

    # Create a remote bob who follows alice. Inbox URL goes through our stub.
    {:ok, bob} =
      Profiles.create_profile(%{
        username: "bob",
        domain: "remote.test",
        remote_url: "http://remote.test/users/bob",
        inbox_url: "http://remote.test/users/bob/inbox",
        shared_inbox_url: nil,
        public_key_pem: "stub"
      })

    Repo.insert!(
      Follower.changeset(%{
        profile_id: alice.id,
        following_id: bob.id,
        accepted_at: DateTime.utc_now()
      })
    )

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

    %{alice: alice, bearer: bearer, bob: bob}
  end

  test "POST /api/v1/statuses → signed Create POSTed to remote follower's inbox", ctx do
    conn =
      ctx.conn
      |> put_req_header("authorization", "Bearer " <> ctx.bearer)
      |> post(~p"/api/v1/statuses", %{
        "status" => "hello federation",
        "visibility" => "public"
      })

    body = json_response(conn, 200)
    status_id = body["id"]
    assert is_binary(status_id)

    # Drain feed (local) and federation_outbound (the signed POST).
    drain_feed = Oban.drain_queue(queue: :feed)
    drain_out = Oban.drain_queue(queue: :federation_outbound)

    if drain_feed.failure > 0 or drain_out.failure > 0 do
      jobs = Oban.Job |> Repo.all() |> Enum.map(fn j -> {j.worker, j.state, j.errors} end)

      flunk(
        "drain failed: feed=#{inspect(drain_feed)} out=#{inspect(drain_out)}\n" <>
          inspect(jobs, pretty: true)
      )
    end

    assert_received {:remote_inbox_post, accept_conn, posted_body}

    activity = Jason.decode!(posted_body)
    assert activity["type"] == "Create"
    assert activity["object"]["type"] == "Note"
    assert activity["object"]["content"] =~ "hello federation"
    assert activity["object"]["attributedTo"] =~ "/users/alice"

    # to: includes Public; cc: alice's followers collection
    assert "https://www.w3.org/ns/activitystreams#Public" in activity["to"]
    assert Enum.any?(activity["cc"], &String.ends_with?(&1, "/followers"))

    # Verify the signature on the outbound POST against alice's public key.
    alice_reloaded = Repo.get!(Angler.Profiles.Profile, ctx.alice.id)
    headers_lower = Enum.map(accept_conn.req_headers, fn {k, v} -> {String.downcase(k), v} end)

    assert :ok =
             HTTPSignature.verify(
               :post,
               "/users/bob/inbox",
               headers_lower,
               posted_body,
               fn _ -> {:ok, alice_reloaded.public_key_pem} end
             )

    # Outbound activity logged in federation_activities.
    assert [%{status: :delivered, activity_type: "Create"}] =
             Repo.all(
               from a in Angler.Federation.Activity,
                 where: a.direction == :outbound and a.activity_type == "Create"
             )
  end

  test "private visibility addresses followers collection only (no Public)", ctx do
    _ =
      ctx.conn
      |> put_req_header("authorization", "Bearer " <> ctx.bearer)
      |> post(~p"/api/v1/statuses", %{"status" => "secret", "visibility" => "private"})

    Oban.drain_queue(queue: :feed)
    Oban.drain_queue(queue: :federation_outbound)

    assert_received {:remote_inbox_post, _conn, posted_body}
    activity = Jason.decode!(posted_body)

    refute "https://www.w3.org/ns/activitystreams#Public" in (activity["to"] ++ activity["cc"])
    assert Enum.any?(activity["to"], &String.ends_with?(&1, "/followers"))
  end
end
