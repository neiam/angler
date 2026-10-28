defmodule Angler.StoriesFederationTest do
  @moduledoc "Inbound federated stories: Add/fetch, View, Story:Reaction/Reply, Delete."

  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.Conversations
  alias Angler.Conversations.Participant
  alias Angler.Federation.Workers.{ActivityHandler, DeleteWorker}
  alias Angler.Follows.Follower
  alias Angler.Notifications.Notification
  alias Angler.Profiles
  alias Angler.Statuses.Status
  alias Angler.Stories
  alias Angler.Stories.{Story, View}
  alias Angler.Stories.Workers.StoryFetch

  @story_url "http://remote.test/stories/bob/42"
  @token "tok_0123456789abcdef"

  setup do
    Application.put_env(:angler, :stories_enabled, true)
    Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})

    on_exit(fn ->
      Application.delete_env(:angler, :stories_enabled)
      Application.delete_env(:angler, :req_options)
    end)

    {:ok, %{profile: alice}} =
      Accounts.register(%{username: "alice", email: "alice@example.com", password: "passwordOK1"})

    bob = remote!("bob", "remote.test")

    %{alice: alice, bob: bob, mallory: remote!("mallory", "evil.test")}
  end

  defp remote!(username, host) do
    {:ok, p} =
      Profiles.create_profile(%{
        username: username,
        domain: host,
        remote_url: "http://#{host}/users/#{username}",
        inbox_url: "http://#{host}/users/#{username}/inbox",
        public_key_pem: "stub"
      })

    p
  end

  # `follower` follows `followee`.
  defp follow!(follower, followee) do
    Repo.insert!(%Follower{
      profile_id: followee.id,
      following_id: follower.id,
      accepted_at: DateTime.utc_now()
    })
  end

  defp deliver(payload, actor) do
    perform_job(ActivityHandler, %{
      "payload" => payload,
      "actor_url" => actor.remote_url,
      "recipient_id" => nil
    })
  end

  describe "Add Story" do
    defp add(actor, url \\ @story_url) do
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => url <> "/activity",
        "type" => "Add",
        "actor" => actor.remote_url,
        "to" => [actor.remote_url <> "/followers"],
        "object" => %{"id" => url, "type" => "Story", "object" => "bear:?t=#{@token}&u=#{url}"}
      }
    end

    defp story_doc(overrides \\ %{}) do
      now = DateTime.utc_now()

      Map.merge(
        %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => @story_url,
          "type" => "Story",
          "to" => ["http://remote.test/users/bob/followers"],
          "attributedTo" => "http://remote.test/users/bob",
          "published" => DateTime.to_iso8601(now),
          "expiresAt" => DateTime.to_iso8601(DateTime.add(now, 86_400, :second)),
          "duration" => 5,
          "can_reply" => true,
          "can_react" => false,
          "attachment" => %{
            "type" => "Image",
            "url" => "http://cdn.remote.test/s/42.jpg",
            "mediaType" => "image/jpeg"
          }
        },
        overrides
      )
    end

    defp serve(doc) do
      test_pid = self()

      Req.Test.stub(:angler_http, fn conn ->
        send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})

        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(200, Jason.encode!(doc))
      end)
    end

    defp fetch_all do
      for job <- all_enqueued(worker: StoryFetch), do: perform_job(StoryFetch, job.args)
    end

    test "a followed account's story is fetched with its bearer and shown", ctx do
      follow!(ctx.alice, ctx.bob)
      serve(story_doc())

      :ok = deliver(add(ctx.bob), ctx.bob)
      assert [:ok] = fetch_all()
      assert_received {:auth, ["Bearer " <> @token]}

      assert [%Story{local: false, active: true, can_reply: true, can_react: false} = story] =
               Repo.all(Story)

      assert story.remote_url == @story_url
      assert story.duration_ms == 5_000

      %{nodes: [node]} = Stories.carousel(ctx.alice)
      assert [%{"src" => "http://cdn.remote.test/s/42.jpg"}] = node["nodes"]

      # Redelivery doesn't mirror it twice.
      :ok = deliver(add(ctx.bob), ctx.bob)
      fetch_all()
      assert Repo.aggregate(Story, :count) == 1
    end

    test "nobody here follows them: not kept", ctx do
      serve(story_doc())
      :ok = deliver(add(ctx.bob), ctx.bob)
      fetch_all()
      assert Repo.all(Story) == []
    end

    test "forgeries are dropped", ctx do
      follow!(ctx.alice, ctx.bob)
      follow!(ctx.alice, ctx.mallory)

      # A bearcap pointing at another server is never fetched.
      :ok = deliver(add(ctx.mallory, @story_url), ctx.mallory)
      assert all_enqueued(worker: StoryFetch) == []

      # The document must be the named story, by the sender.
      serve(story_doc(%{"attributedTo" => "http://remote.test/users/carol"}))
      :ok = deliver(add(ctx.bob), ctx.bob)
      fetch_all()

      serve(story_doc(%{"id" => "http://remote.test/stories/bob/43"}))

      perform_job(StoryFetch, %{
        "url" => @story_url,
        "token" => @token,
        "actor_url" => ctx.bob.remote_url
      })

      serve(
        story_doc(%{
          "attachment" => %{"type" => "Image", "url" => "http://x/y", "mediaType" => "text/html"}
        })
      )

      perform_job(StoryFetch, %{
        "url" => @story_url,
        "token" => @token,
        "actor_url" => ctx.bob.remote_url
      })

      assert Repo.all(Story) == []
    end

    test "the bearer isn't sent past a redirect to another host", ctx do
      test_pid = self()

      Req.Test.stub(:angler_http, fn conn ->
        send(test_pid, {conn.host, Plug.Conn.get_req_header(conn, "authorization")})

        case conn.host do
          "remote.test" ->
            conn
            |> Plug.Conn.put_resp_header("location", "http://elsewhere.test/story")
            |> Plug.Conn.send_resp(302, "")

          _ ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      perform_job(StoryFetch, %{
        "url" => @story_url,
        "token" => @token,
        "actor_url" => ctx.bob.remote_url
      })

      assert_received {"remote.test", ["Bearer " <> @token]}
      assert_received {"elsewhere.test", []}
    end

    test "Delete Story: only the owner takes it down", ctx do
      follow!(ctx.alice, ctx.bob)
      serve(story_doc())
      :ok = deliver(add(ctx.bob), ctx.bob)
      fetch_all()

      delete = fn actor ->
        perform_job(DeleteWorker, %{
          "activity" => %{
            "type" => "Delete",
            "actor" => actor.remote_url,
            "object" => %{"type" => "Story", "id" => @story_url}
          }
        })
      end

      :ok = delete.(ctx.mallory)
      assert Repo.aggregate(Story, :count) == 1

      :ok = delete.(ctx.bob)
      assert Repo.all(Story) == []
    end
  end

  describe "interactions with a local story" do
    setup ctx do
      story =
        %Story{}
        |> Story.changeset(%{
          profile_id: ctx.alice.id,
          type: "photo",
          mime: "image/jpeg",
          path: "story.jpg",
          active: true,
          can_reply: true,
          can_react: true,
          expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
        })
        |> Repo.insert!()

      url = AnglerWeb.Endpoint.url() <> "/stories/alice/#{story.id}"
      %{story: story, url: url}
    end

    defp interaction(ctx, type, actor, extra \\ %{}) do
      Map.merge(
        %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => "#{actor.remote_url}/statuses/1/activity",
          "type" => type,
          "actor" => actor.remote_url,
          "to" => Profiles.actor_url(ctx.alice),
          "inReplyTo" => ctx.url,
          "content" => "<p>nice &amp; sunny</p>"
        },
        extra
      )
    end

    test "a follower's reaction lands in a DM conversation", ctx do
      follow!(ctx.bob, ctx.alice)
      :ok = deliver(interaction(ctx, "Story:Reaction", ctx.bob), ctx.bob)

      assert [%Status{} = status] = Repo.all(from s in Status, where: s.visibility == :direct)
      assert status.type == "story:reaction"
      assert status.story_id == ctx.story.id
      assert status.caption == "nice & sunny"
      assert status.uri == "http://remote.test/users/bob/statuses/1"

      conversation = Conversations.between(ctx.bob.id, ctx.alice.id)
      assert Conversations.message?(conversation.id, status.id)

      assert %Participant{state: "active", unread_count: 1} =
               Repo.get_by(Participant,
                 conversation_id: conversation.id,
                 profile_id: ctx.alice.id
               )

      assert Repo.exists?(from n in Notification, where: n.recipient_id == ^ctx.alice.id)

      assert {"story:react", %{"story_id" => sid, "reaction" => "nice & sunny"}} =
               Stories.message_meta(status)

      assert sid == Integer.to_string(ctx.story.id)

      # Redelivery is a no-op.
      :ok = deliver(interaction(ctx, "Story:Reaction", ctx.bob), ctx.bob)
      assert Repo.aggregate(from(s in Status, where: s.visibility == :direct), :count) == 1
    end

    test "a reply becomes a story:reply DM", ctx do
      follow!(ctx.bob, ctx.alice)
      :ok = deliver(interaction(ctx, "Story:Reply", ctx.bob), ctx.bob)

      assert [%Status{type: "story:reply"} = status] =
               Repo.all(from s in Status, where: s.visibility == :direct)

      assert {"story:comment", %{"caption" => "nice & sunny"}} = Stories.message_meta(status)
    end

    test "non-followers, closed stories, forgeries and blocks are dropped", ctx do
      # Not a follower.
      :ok = deliver(interaction(ctx, "Story:Reaction", ctx.bob), ctx.bob)

      follow!(ctx.bob, ctx.alice)
      follow!(ctx.mallory, ctx.alice)

      # Speaking for someone else, or from another host.
      :ok = deliver(interaction(ctx, "Story:Reaction", ctx.bob), ctx.mallory)

      :ok =
        deliver(
          interaction(ctx, "Story:Reaction", ctx.mallory, %{
            "id" => "http://remote.test/statuses/9"
          }),
          ctx.mallory
        )

      # Addressed to someone other than the story's author.
      {:ok, %{profile: carol}} =
        Accounts.register(%{username: "carol", email: "c@example.com", password: "passwordOK1"})

      :ok =
        deliver(
          interaction(ctx, "Story:Reaction", ctx.bob, %{"to" => Profiles.actor_url(carol)}),
          ctx.bob
        )

      # Reactions turned off.
      ctx.story |> Ecto.Changeset.change(can_react: false) |> Repo.update!()
      :ok = deliver(interaction(ctx, "Story:Reaction", ctx.bob), ctx.bob)

      # The author blocks the domain.
      :ok = Profiles.DomainBlocks.block(ctx.alice, "remote.test")
      :ok = deliver(interaction(ctx, "Story:Reply", ctx.bob), ctx.bob)

      assert Repo.all(from s in Status, where: s.visibility == :direct) == []
    end

    test "a follower's View is recorded; anyone else's isn't", ctx do
      view = fn actor ->
        deliver(
          %{
            "id" => actor.remote_url <> "#stories/#{ctx.story.id}/view",
            "type" => "View",
            "actor" => actor.remote_url,
            "to" => Profiles.actor_url(ctx.alice),
            "object" => %{"type" => "Story", "object" => ctx.url}
          },
          actor
        )
      end

      :ok = view.(ctx.mallory)
      assert Repo.all(View) == []

      follow!(ctx.bob, ctx.alice)
      :ok = view.(ctx.bob)
      assert [%View{profile_id: pid}] = Repo.all(View)
      assert pid == ctx.bob.id
      assert Repo.get(Story, ctx.story.id).view_count == 1
    end
  end
end
