defmodule Angler.Federation.RelaysTest do
  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Federation.Relays
  alias Angler.Federation.Workers.RelayDeliver
  alias Angler.Statuses

  describe "subscription lifecycle" do
    setup do
      # subscribe/1 fetches the relay actor to discover its inbox.
      Req.Test.stub(:angler_http, fn conn ->
        case conn.request_path do
          "/actor" ->
            json(conn, %{
              "id" => "http://relay.test/actor",
              "type" => "Application",
              "inbox" => "http://relay.test/inbox"
            })

          _ ->
            Plug.Conn.send_resp(conn, 404, "not stubbed")
        end
      end)

      Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})
      on_exit(fn -> Application.delete_env(:angler, :req_options) end)
      Req.Test.set_req_test_to_shared(self())
      :ok
    end

    test "subscribe discovers the inbox, creates a pending row, and enqueues a Follow" do
      {:ok, relay} = Relays.subscribe("http://relay.test/actor")

      assert relay.state == :pending
      assert relay.actor_url == "http://relay.test/actor"
      assert relay.inbox_url == "http://relay.test/inbox"
      assert is_binary(relay.follow_activity_id)

      assert_enqueued(
        worker: RelayDeliver,
        args: %{
          "verb" => "follow",
          "inbox_url" => "http://relay.test/inbox",
          "object_url" => "http://relay.test/actor"
        }
      )
    end

    test "duplicate actor is rejected" do
      {:ok, _} = Relays.subscribe("http://relay.test/actor")
      assert {:error, %Ecto.Changeset{}} = Relays.subscribe("http://relay.test/actor")
    end

    test "accept marks accepted, confirms the relay actor, and gates the firehose" do
      {:ok, relay} = Relays.subscribe("http://relay.test/actor")
      refute Relays.relay_actor?("http://relay.test/actor")

      assert :ok = Relays.accept(relay.follow_activity_id, "http://relay.test/actor")

      reloaded = Relays.get(relay.id)
      assert reloaded.state == :accepted
      assert reloaded.actor_url == "http://relay.test/actor"
      assert Relays.relay_actor?("http://relay.test/actor")
    end

    test "accept of an unknown Follow id falls through" do
      assert :not_found = Relays.accept("urn:nope", "http://relay.test/actor")
    end

    test "disable sends an Undo and marks idle" do
      {:ok, relay} = Relays.subscribe("http://relay.test/actor")
      :ok = Relays.accept(relay.follow_activity_id, "http://relay.test/actor")

      {:ok, disabled} = Relays.disable(Relays.get(relay.id))
      assert disabled.state == :idle
      refute Relays.relay_actor?("http://relay.test/actor")

      assert_enqueued(worker: RelayDeliver, args: %{"verb" => "undo"})
    end

    test "enable re-sends a Follow with a fresh id" do
      {:ok, relay} = Relays.subscribe("http://relay.test/actor")
      {:ok, _} = Relays.disable(relay)

      {:ok, enabled} = Relays.enable(Relays.get(relay.id))
      assert enabled.state == :pending
      assert enabled.follow_activity_id != relay.follow_activity_id
    end

    test "unsubscribe of an accepted relay sends an Undo and deletes the row" do
      {:ok, relay} = Relays.subscribe("http://relay.test/actor")
      :ok = Relays.accept(relay.follow_activity_id, "http://relay.test/actor")

      assert :ok = Relays.unsubscribe(Relays.get(relay.id))
      assert Relays.get(relay.id) == nil
      assert_enqueued(worker: RelayDeliver, args: %{"verb" => "undo"})
    end

    test "get_by_actor_url finds a relay" do
      {:ok, relay} = Relays.subscribe("http://relay.test/actor")
      assert Relays.get_by_actor_url("http://relay.test/actor").id == relay.id
      assert Relays.get_by_actor_url("http://relay.test/missing") == nil
    end

    test "Release CLI helpers follow, list, and unfollow by actor or id" do
      import ExUnit.CaptureIO

      assert capture_io(fn -> Angler.Release.relay_list() end) =~ "No relays configured."

      assert capture_io(fn -> Angler.Release.relay_follow("http://relay.test/actor") end) =~
               "Following relay"

      [relay] = Relays.list()
      assert capture_io(fn -> Angler.Release.relay_list() end) =~ "http://relay.test/actor"

      # Unfollow accepts either the actor URL or the numeric id.
      assert capture_io(fn -> Angler.Release.relay_unfollow(relay.id) end) =~ "Unfollowed relay"
      assert Relays.list() == []
    end
  end

  describe "ingest_announced/1 (firehose)" do
    setup do
      author_url = "http://remote.test/users/carol"

      actor_doc = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => author_url,
        "type" => "Person",
        "preferredUsername" => "carol",
        "inbox" => author_url <> "/inbox",
        "publicKey" => %{
          "id" => author_url <> "#main-key",
          "owner" => author_url,
          "publicKeyPem" => "stub-key"
        }
      }

      note_uri = "http://remote.test/notes/relayed-1"

      note_doc = %{
        "type" => "Note",
        "id" => note_uri,
        "url" => note_uri,
        "attributedTo" => author_url,
        "content" => "<p>relayed firehose post</p>",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "sensitive" => false
      }

      Req.Test.stub(:angler_http, fn conn ->
        case conn.request_path do
          "/users/carol" -> json(conn, actor_doc)
          "/notes/relayed-1" -> json(conn, note_doc)
          _ -> Plug.Conn.send_resp(conn, 404, "not stubbed")
        end
      end)

      Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})
      on_exit(fn -> Application.delete_env(:angler, :req_options) end)
      Req.Test.set_req_test_to_shared(self())

      %{note_uri: note_uri}
    end

    test "fetches a bare-URI Announce target and ingests it as a public status", ctx do
      announce = %{
        "id" => ctx.note_uri <> "/announce",
        "type" => "Announce",
        "actor" => "http://relay.test/actor",
        "object" => ctx.note_uri
      }

      assert :ok = Angler.Statuses.Federation.ingest_announced(announce)

      status = Statuses.get_by_uri(ctx.note_uri)
      assert status
      assert status.visibility == :public
      assert status.local == false
    end

    test "is idempotent", ctx do
      announce = %{
        "id" => ctx.note_uri <> "/announce",
        "type" => "Announce",
        "actor" => "http://relay.test/actor",
        "object" => ctx.note_uri
      }

      assert :ok = Angler.Statuses.Federation.ingest_announced(announce)
      assert :ok = Angler.Statuses.Federation.ingest_announced(announce)

      assert Repo.aggregate(
               from(s in Angler.Statuses.Status, where: s.uri == ^ctx.note_uri),
               :count
             ) == 1
    end
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/activity+json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
