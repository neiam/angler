defmodule Angler.Federation.BackfillTest do
  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.Federation.Backfill
  alias Angler.Notifications.Notification
  alias Angler.Profiles
  alias Angler.Snowflake
  alias Angler.Statuses
  alias Angler.Statuses.Status
  alias Angler.Timelines.Workers.FeedInsert

  @public "https://www.w3.org/ns/activitystreams#Public"
  @actor "http://remote.test/users/alice"

  setup do
    {:ok, %{user: local}} =
      Accounts.register(%{username: "bob", email: "bob@example.com", password: "verysecret123"})

    {:ok, alice} =
      Profiles.create_profile(%{
        username: "alice",
        domain: "remote.test",
        remote_url: @actor,
        inbox_url: @actor <> "/inbox",
        outbox_url: @actor <> "/outbox",
        followers_url: @actor <> "/followers",
        public_key_pem: "stub"
      })

    %{alice: alice, local: local}
  end

  defp note(n, published, extra \\ %{}) do
    Map.merge(
      %{
        "id" => "http://remote.test/notes/#{n}",
        "type" => "Note",
        "attributedTo" => @actor,
        "content" => "<p>note #{n}</p>",
        "published" => published,
        "to" => [@public],
        "cc" => [@actor <> "/followers"]
      },
      extra
    )
  end

  defp create(object, actor \\ @actor),
    do: %{"type" => "Create", "actor" => actor, "object" => object}

  defp stub_outbox(pages) do
    Req.Test.stub(:angler_http, fn conn ->
      body =
        case {conn.request_path, conn.query_string} do
          {"/users/alice/outbox", ""} ->
            %{
              "type" => "OrderedCollection",
              "totalItems" => 99,
              "first" => @actor <> "/outbox?page=1"
            }

          {"/users/alice/outbox", "page=" <> n} ->
            Map.fetch!(pages, String.to_integer(n))
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/activity+json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)

    Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})
    on_exit(fn -> Application.delete_env(:angler, :req_options) end)
    Req.Test.set_req_test_to_shared(self())
  end

  test "imports public posts from the outbox, backdated and quietly", %{alice: alice} do
    stub_outbox(%{
      1 => %{
        "type" => "OrderedCollectionPage",
        "id" => @actor <> "/outbox?page=1",
        "next" => @actor <> "/outbox?page=2",
        "orderedItems" => [
          create(
            note(1, "2024-05-01T12:00:00Z", %{
              "tag" => [
                %{"type" => "Mention", "href" => AnglerWeb.Endpoint.url() <> "/users/bob"}
              ]
            })
          ),
          %{"type" => "Announce", "actor" => @actor, "object" => "http://else.test/n/1"},
          create(
            note(9, "2024-04-01T00:00:00Z", %{"attributedTo" => "http://remote.test/users/eve"})
          ),
          create(note(3, "2024-03-01T00:00:00Z", %{"to" => [@actor <> "/followers"], "cc" => []}))
        ]
      },
      2 => %{
        "type" => "OrderedCollectionPage",
        "id" => @actor <> "/outbox?page=2",
        "orderedItems" => [create(note(2, "2023-01-15T08:30:00Z"))]
      }
    })

    assert {:ok, %{imported: 2, skipped: 3, existing: 0, failed: 0}} = Backfill.run(alice)

    newer = Statuses.get_by_uri("http://remote.test/notes/1")
    older = Statuses.get_by_uri("http://remote.test/notes/2")

    assert newer.inserted_at == ~U[2024-05-01 12:00:00.000000Z]
    assert older.inserted_at == ~U[2023-01-15 08:30:00.000000Z]
    assert Snowflake.timestamp(older.id) == DateTime.to_unix(older.inserted_at, :millisecond)
    assert older.id < newer.id

    refute_enqueued(worker: FeedInsert)
    # bob is mentioned, but not notified about a years-old post.
    assert Repo.exists?(from m in Angler.Statuses.Mention, where: m.status_id == ^newer.id)
    assert Repo.aggregate(Notification, :count) == 0

    # A second run finds them already here.
    assert {:ok, %{imported: 0, existing: 2}} = Backfill.run(alice)
  end

  test "stops at the limit", %{alice: alice} do
    stub_outbox(%{
      1 => %{
        "type" => "OrderedCollectionPage",
        "orderedItems" => [
          create(note(1, "2024-05-01T00:00:00Z")),
          create(note(2, "2024-04-01T00:00:00Z")),
          create(note(3, "2024-03-01T00:00:00Z"))
        ]
      }
    })

    assert {:ok, %{imported: 2}} = Backfill.run(alice, limit: 2)
    assert Repo.aggregate(Status, :count) == 2
  end

  describe "after_follow" do
    alias Angler.Federation.Workers.Backfill, as: BackfillWorker

    defp local!(name) do
      {:ok, %{user: user}} =
        Accounts.register(%{
          username: name,
          email: "#{name}@example.com",
          password: "verysecret123"
        })

      Profiles.get_profile(user.profile_id)
    end

    test "the first local follow queues a backfill, later ones don't", %{alice: alice, local: bob} do
      {:ok, :pending_remote, _} =
        Angler.Follows.follow(Profiles.get_profile(bob.profile_id), alice)

      assert_enqueued(worker: BackfillWorker, args: %{"profile_id" => alice.id, "limit" => 160})

      Repo.delete_all(Oban.Job)
      {:ok, :pending_remote, _} = Angler.Follows.follow(local!("carol"), alice)
      refute_enqueued(worker: BackfillWorker)
    end

    test "can be switched off", %{alice: alice, local: bob} do
      Application.put_env(:angler, Backfill, on_follow: false)
      on_exit(fn -> Application.delete_env(:angler, Backfill) end)

      {:ok, :pending_remote, _} =
        Angler.Follows.follow(Profiles.get_profile(bob.profile_id), alice)

      refute_enqueued(worker: BackfillWorker)
    end

    test "skips private accounts", %{alice: alice, local: bob} do
      alice = alice |> Ecto.Changeset.change(is_private: true) |> Repo.update!()

      {:ok, :pending_remote, _} =
        Angler.Follows.follow(Profiles.get_profile(bob.profile_id), alice)

      refute_enqueued(worker: BackfillWorker)
    end
  end

  test "ignores an outbox on another host", %{alice: alice} do
    alice = %{alice | outbox_url: "http://evil.test/outbox"}
    assert {:error, :foreign_outbox} = Backfill.run(alice)
  end
end
