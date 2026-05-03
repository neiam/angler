defmodule Angler.Integration.FederationOutboundInteractionE2ETest do
  @moduledoc """
  End-to-end: alice favourites a remote bob status; outbound signed `Like`
  arrives at bob's inbox. Then unfavourite → signed `Undo Like`.
  """

  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.Federation.HTTPSignature
  alias Angler.OAuth
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses

  setup do
    {:ok, %{user: user, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: client} = OAuth.first_party_client!()
    {:ok, %{access: write}} = OAuth.issue_token(user, client, scopes: ["write"])

    bob_actor_url = "http://remote.test/users/bob"

    {:ok, bob} =
      Profiles.create_profile(%{
        username: "bob",
        domain: "remote.test",
        remote_url: bob_actor_url,
        inbox_url: "http://remote.test/users/bob/inbox",
        public_key_pem: "stub"
      })

    note_uri = "http://remote.test/notes/likeable"

    {:ok, status} =
      Statuses.create_remote(%{
        profile_id: bob.id,
        visibility: :public,
        caption: "like me",
        rendered: "<p>like me</p>",
        type: "text",
        local: false,
        uri: note_uri,
        url: note_uri
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

    %{alice: alice, status: status, write: write}
  end

  test "favourite remote → signed Like POSTed to author's inbox", ctx do
    conn =
      ctx.conn
      |> put_req_header("authorization", "Bearer " <> ctx.write)
      |> post(~p"/api/v1/statuses/#{Integer.to_string(ctx.status.id)}/favourite")

    body = json_response(conn, 200)
    assert body["favourited"] == true

    drain = Oban.drain_queue(queue: :federation_outbound)
    assert drain.failure == 0

    assert_received {:remote_inbox_post, peer_conn, posted_body}
    activity = Jason.decode!(posted_body)
    assert activity["type"] == "Like"
    assert activity["object"] == ctx.status.uri
    assert activity["actor"] =~ "/users/alice"

    # Verify outbound signature.
    alice_reloaded = Repo.get!(Profile, ctx.alice.id)
    headers_lower = Enum.map(peer_conn.req_headers, fn {k, v} -> {String.downcase(k), v} end)

    assert :ok =
             HTTPSignature.verify(
               :post,
               "/users/bob/inbox",
               headers_lower,
               posted_body,
               fn _ -> {:ok, alice_reloaded.public_key_pem} end
             )
  end

  test "unfavourite remote → signed Undo Like wrapping the original Like", ctx do
    # Favourite first; drain + consume.
    _ =
      ctx.conn
      |> put_req_header("authorization", "Bearer " <> ctx.write)
      |> post(~p"/api/v1/statuses/#{Integer.to_string(ctx.status.id)}/favourite")

    Oban.drain_queue(queue: :federation_outbound)
    assert_received {:remote_inbox_post, _conn, like_body}
    like_activity = Jason.decode!(like_body)
    original_like_id = like_activity["id"]

    # Unfavourite.
    _ =
      ctx.conn
      |> put_req_header("authorization", "Bearer " <> ctx.write)
      |> post(~p"/api/v1/statuses/#{Integer.to_string(ctx.status.id)}/unfavourite")

    Oban.drain_queue(queue: :federation_outbound)
    assert_received {:remote_inbox_post, _conn, undo_body}
    undo = Jason.decode!(undo_body)
    assert undo["type"] == "Undo"
    assert undo["object"]["type"] == "Like"
    assert undo["object"]["id"] == original_like_id
    assert undo["object"]["object"] == ctx.status.uri
  end

  test "reblog remote → signed Announce; unreblog → Undo Announce", ctx do
    _ =
      ctx.conn
      |> put_req_header("authorization", "Bearer " <> ctx.write)
      |> post(~p"/api/v1/statuses/#{Integer.to_string(ctx.status.id)}/reblog")

    Oban.drain_queue(queue: :federation_outbound)
    assert_received {:remote_inbox_post, _conn, announce_body}
    announce = Jason.decode!(announce_body)
    assert announce["type"] == "Announce"
    assert announce["object"] == ctx.status.uri
    original_announce_id = announce["id"]

    _ =
      ctx.conn
      |> put_req_header("authorization", "Bearer " <> ctx.write)
      |> post(~p"/api/v1/statuses/#{Integer.to_string(ctx.status.id)}/unreblog")

    Oban.drain_queue(queue: :federation_outbound)
    assert_received {:remote_inbox_post, _conn, undo_body}
    undo = Jason.decode!(undo_body)
    assert undo["type"] == "Undo"
    assert undo["object"]["type"] == "Announce"
    assert undo["object"]["id"] == original_announce_id
  end
end
