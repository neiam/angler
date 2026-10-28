defmodule Angler.StoriesOutboundTest do
  @moduledoc "Outbound federated stories: Add/Delete fan-out, View, Story:Reaction/Reply."

  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.Conversations
  alias Angler.Federation.DeliveryHosts
  alias Angler.Follows.Follower
  alias Angler.Profiles
  alias Angler.Statuses.Status
  alias Angler.Stories
  alias Angler.Stories.{Federation, Outbound, Story}
  alias Angler.Stories.Workers.StoryDeliver

  setup do
    Application.put_env(:angler, :stories_enabled, true)
    Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})

    on_exit(fn ->
      Application.delete_env(:angler, :stories_enabled)
      Application.delete_env(:angler, :req_options)
    end)

    {:ok, %{profile: alice}} =
      Accounts.register(%{username: "alice", email: "alice@example.com", password: "passwordOK1"})

    %{alice: Repo.reload!(alice), bob: remote!("bob", "remote.test")}
  end

  defp remote!(username, host) do
    {:ok, p} =
      Profiles.create_profile(%{
        username: username,
        domain: host,
        remote_url: "http://#{host}/users/#{username}",
        inbox_url: "http://#{host}/users/#{username}/inbox",
        shared_inbox_url: "http://#{host}/inbox",
        public_key_pem: "stub"
      })

    p
  end

  defp follow!(follower, followee) do
    Repo.insert!(%Follower{
      profile_id: followee.id,
      following_id: follower.id,
      accepted_at: DateTime.utc_now()
    })
  end

  defp story!(author, attrs \\ %{}) do
    %Story{}
    |> Story.changeset(
      Map.merge(
        %{
          profile_id: author.id,
          type: "photo",
          mime: "image/jpeg",
          path: "story.jpg",
          expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp remote_story!(author) do
    story!(author, %{
      local: false,
      active: true,
      remote_url: "http://remote.test/stories/bob/42",
      path: "http://cdn.remote.test/s/42.jpg"
    })
  end

  defp deliveries, do: all_enqueued(worker: StoryDeliver)

  defp capture_posts do
    test_pid = self()

    Req.Test.stub(:angler_http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:post, conn.host, conn.request_path, conn.req_headers, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 202, "")
    end)
  end

  describe "local stories" do
    test "publishing sends an Add with the bearcap to remote followers", ctx do
      follow!(ctx.bob, ctx.alice)
      draft = story!(ctx.alice)
      {:ok, story} = Stories.publish(ctx.alice, draft.id, %{})

      assert [job] = deliveries()
      assert job.args["inbox_url"] == "http://remote.test/inbox"
      assert job.args["sync"] == true

      url = Outbound.url(story, ctx.alice)

      assert %{"type" => "Add", "object" => %{"id" => ^url, "type" => "Story", "object" => cap}} =
               job.args["activity"]

      # What the inbound side would accept from us.
      assert {:ok, %{url: ^url, token: token}} = Federation.decode_bearcap(cap)
      assert token == story.bearcap_token

      capture_posts()
      assert :ok = perform_job(StoryDeliver, job.args)

      assert_received {:post, "remote.test", "/inbox", headers, %{"type" => "Add"}}
      assert List.keymember?(headers, "signature", 0)
      assert List.keymember?(headers, "collection-synchronization", 0)
    end

    test "nothing goes out with stories off, or without remote followers", ctx do
      {:ok, _} = Stories.publish(ctx.alice, story!(ctx.alice).id, %{})
      assert deliveries() == []

      follow!(ctx.bob, ctx.alice)
      Application.put_env(:angler, :stories_enabled, false)
      {:ok, _} = Stories.publish(ctx.alice, story!(ctx.alice).id, %{})
      assert deliveries() == []
    end

    test "taking a story down or expiring it sends a Delete", ctx do
      follow!(ctx.bob, ctx.alice)
      story = story!(ctx.alice, %{active: true})
      url = Outbound.url(story, ctx.alice)

      :ok = Stories.delete(ctx.alice, story.id)

      assert [%{args: %{"activity" => %{"type" => "Delete", "object" => %{"id" => ^url}}}}] =
               deliveries()

      expired =
        story!(ctx.alice, %{
          active: true,
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      assert Stories.expire_due() == 1
      expired_url = Outbound.url(expired, ctx.alice)

      assert Enum.any?(deliveries(), &(&1.args["activity"]["object"]["id"] == expired_url))
    end

    test "a backed-off host is skipped and the job cancelled", ctx do
      follow!(ctx.bob, ctx.alice)
      {:ok, _} = Stories.publish(ctx.alice, story!(ctx.alice).id, %{})
      [job] = deliveries()

      for _ <- 1..5, do: DeliveryHosts.record_failure("remote.test")
      capture_posts()

      assert {:cancel, :host_unavailable} = perform_job(StoryDeliver, job.args)
      refute_received {:post, _, _, _, _}
    end
  end

  describe "remote stories" do
    setup ctx do
      follow!(ctx.alice, ctx.bob)
      %{story: remote_story!(ctx.bob)}
    end

    test "a first view is reported to the author", ctx do
      {:ok, _} = Stories.mark_seen(ctx.alice, ctx.story.id)
      {:ok, _} = Stories.mark_seen(ctx.alice, ctx.story.id)

      assert [job] = deliveries()
      assert job.args["inbox_url"] == ctx.bob.inbox_url
      assert job.args["sync"] == false

      assert %{
               "type" => "View",
               "actor" => actor,
               "to" => "http://remote.test/users/bob",
               "object" => %{"type" => "Story", "object" => "http://remote.test/stories/bob/42"}
             } = job.args["activity"]

      assert actor == Profiles.actor_url(ctx.alice)
    end

    test "a reply is a story:reply DM and a Story:Reply to the author", ctx do
      assert {:ok, %Status{} = status} = Stories.comment(ctx.alice, ctx.story.id, "lovely")

      assert status.type == "story:reply"
      assert status.story_id == ctx.story.id
      assert status.local
      assert status.uri =~ "/p/alice/#{status.id}"

      conversation = Conversations.between(ctx.alice.id, ctx.bob.id)
      assert Conversations.message?(conversation.id, status.id)

      assert {"story:comment", %{"caption" => "lovely", "story_id" => sid}} =
               Stories.message_meta(status)

      assert sid == Integer.to_string(ctx.story.id)

      assert [job] = deliveries()
      uri = status.uri

      assert %{
               "type" => "Story:Reply",
               "id" => ^uri,
               "content" => "lovely",
               "inReplyTo" => "http://remote.test/stories/bob/42",
               "to" => "http://remote.test/users/bob"
             } = job.args["activity"]

      # Not sent as an ordinary DM too.
      assert all_enqueued(worker: Angler.Statuses.Workers.StatusDeliver) == []
    end

    test "reactions are capped per story", ctx do
      for _ <- 1..5, do: assert({:ok, _} = Stories.react(ctx.alice, ctx.story.id, "🔥"))
      assert {:error, :limit_reached} = Stories.react(ctx.alice, ctx.story.id, "🔥")

      assert length(deliveries()) == 5

      assert Enum.all?(deliveries(), &(&1.args["activity"]["type"] == "Story:Reaction"))

      ctx.story |> Ecto.Changeset.change(can_react: false) |> Repo.update!()
      assert {:error, :reactions_disabled} = Stories.react(ctx.alice, ctx.story.id, "🔥")
    end

    test "non-followers can't reply", ctx do
      Repo.delete_all(Follower)
      assert {:error, :not_found} = Stories.comment(ctx.alice, ctx.story.id, "hi")
      assert deliveries() == []
    end
  end
end
