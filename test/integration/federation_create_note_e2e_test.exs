defmodule Angler.Integration.FederationCreateNoteE2ETest do
  @moduledoc """
  End-to-end: signed `Create Note` from a remote actor → InboxValidator
  verifies sig → ActivityHandler dispatches to Statuses.Federation →
  Status row materialized → GET /api/v1/statuses/:id returns the
  Mastodon-shape JSON.
  """

  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.Federation.HTTPSignature
  alias Angler.OAuth
  alias Angler.Profiles
  alias Angler.Profiles.Keypair
  alias Angler.Statuses
  alias Angler.Repo

  setup do
    {:ok, _alice_profile} = Profiles.create_profile(%{username: "alice"})

    {:ok, %{user: viewer}} =
      Accounts.register(%{
        username: "viewer",
        email: "viewer@example.com",
        password: "verysecret123"
      })

    %{client: client} = OAuth.first_party_client!()
    {:ok, %{access: bearer}} = OAuth.issue_token(viewer, client)

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

    Req.Test.stub(:angler_http, fn conn ->
      case conn do
        %Plug.Conn{method: "GET", request_path: "/users/bob"} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/activity+json")
          |> Plug.Conn.send_resp(200, Jason.encode!(actor_doc))

        other ->
          Plug.Conn.send_resp(other, 404, "not stubbed")
      end
    end)

    Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})
    on_exit(fn -> Application.delete_env(:angler, :req_options) end)
    Req.Test.set_req_test_to_shared(self())

    %{
      bearer: bearer,
      remote_actor_url: remote_actor_url,
      remote_priv_pem: remote_priv_pem
    }
  end

  test "signed Create Note → status materialized → visible via API", ctx do
    note_uri = "http://remote.test/notes/hello-world"
    activity_id = note_uri <> "/activity"

    payload = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Create",
      "actor" => ctx.remote_actor_url,
      "object" => %{
        "type" => "Note",
        "id" => note_uri,
        "url" => note_uri,
        "attributedTo" => ctx.remote_actor_url,
        "content" => "<p>hello world from <a href=\"#\">@alice</a></p>",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [AnglerWeb.Endpoint.url() <> "/users/alice"],
        "tag" => [
          %{
            "type" => "Mention",
            "name" => "@alice",
            "href" => AnglerWeb.Endpoint.url() <> "/users/alice"
          },
          %{"type" => "Hashtag", "name" => "#hello", "href" => "x"}
        ],
        "sensitive" => false
      }
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
      |> Enum.reject(fn {k, _v} -> String.downcase(k) == "host" end)
      |> Enum.reduce(conn, fn {k, v}, c ->
        put_req_header(c, String.downcase(k), v)
      end)

    conn = Phoenix.ConnTest.dispatch(conn, @endpoint, :post, path, body)
    assert response(conn, 202) == ""

    drain = Oban.drain_queue(queue: :federation_inbound, with_recursion: true)

    if drain.failure > 0 do
      jobs = Oban.Job |> Repo.all() |> Enum.map(fn j -> {j.worker, j.state, j.errors} end)
      flunk("inbound drain failed: #{inspect(drain)}\n#{inspect(jobs, pretty: true)}")
    end

    # Status was created.
    status = Statuses.get_by_uri(note_uri)
    assert status
    assert status.local == false
    assert status.visibility == :public

    # Mention + hashtag attached.
    status = Repo.preload(status, [:mentions, status_hashtags: :hashtag])
    alice_id = Repo.get_by!(Angler.Profiles.Profile, username: "alice").id
    assert Enum.any?(status.mentions, &(&1.profile_id == alice_id))
    assert Enum.any?(status.status_hashtags, &(&1.hashtag.name == "hello"))

    # GET /api/v1/statuses/:id returns the rendered shape.
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> ctx.bearer)
      |> get(~p"/api/v1/statuses/#{Integer.to_string(status.id)}")

    body = json_response(conn, 200)
    assert body["id"] == Integer.to_string(status.id)
    assert body["uri"] == note_uri
    assert body["visibility"] == "public"
    assert body["content"] =~ "hello world"
    assert body["account"]["username"] == "bob"
    assert body["account"]["acct"] == "bob@remote.test"
    assert Enum.any?(body["mentions"], &(&1["username"] == "alice"))
    assert Enum.any?(body["tags"], &(&1["name"] == "hello"))

    # Mention notification was created for alice.
    notifications = Repo.all(Angler.Notifications.Notification)
    assert Enum.any?(notifications, &(&1.type == "mention" and &1.recipient_id == alice_id))
  end
end
