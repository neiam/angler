defmodule Angler.TimelinesTest do
  use Angler.DataCase, async: false

  alias Angler.Follows.Follower
  alias Angler.Hashtags
  alias Angler.Pagination.MastodonCursor
  alias Angler.Profiles
  alias Angler.Statuses
  alias Angler.Statuses.{Status, StatusHashtag}
  alias Angler.Timelines
  alias Angler.Timelines.HomeFeedEntry
  alias Angler.Timelines.Workers.FeedInsert

  defp local!(username) do
    {:ok, p} = Profiles.create_profile(%{username: username})
    p
  end

  defp remote!(username) do
    {:ok, p} =
      Profiles.create_profile(%{
        username: username,
        domain: "remote.test",
        remote_url: "http://remote.test/users/#{username}",
        inbox_url: "http://remote.test/users/#{username}/inbox",
        public_key_pem: "stub"
      })

    p
  end

  defp insert_status!(profile, attrs \\ %{}) do
    base = %{
      profile_id: profile.id,
      visibility: :public,
      caption: "hi",
      rendered: "<p>hi</p>",
      type: "text",
      local: is_nil(profile.domain),
      uri:
        if(is_nil(profile.domain),
          do: nil,
          else: "http://remote.test/notes/#{System.unique_integer([:positive])}"
        )
    }

    {:ok, status} = Statuses.create_remote(Map.merge(base, attrs))
    status
  end

  defp default_cursor, do: MastodonCursor.parse(%{}, 20, 40)

  ## Home

  describe "home/2" do
    setup do
      alice = local!("alice")
      bob = remote!("bob")

      # Alice follows bob.
      {:ok, _} =
        %Follower{}
        |> Follower.changeset(%{
          profile_id: bob.id,
          following_id: alice.id,
          accepted_at: DateTime.utc_now()
        })
        |> Repo.insert()

      %{alice: alice, bob: bob}
    end

    test "empty for a user with no follows" do
      eve = local!("eve")
      assert {[], []} = Timelines.home(eve.id, default_cursor())
    end

    test "shows fanned-in statuses descending", ctx do
      s1 = insert_status!(ctx.bob)
      s2 = insert_status!(ctx.bob)
      s3 = insert_status!(ctx.bob)

      Enum.each([s1, s2, s3], fn s -> {:ok, _} = FeedInsert.enqueue(s.id) end)
      Oban.drain_queue(queue: :feed)

      {statuses, _cursor_rows} = Timelines.home(ctx.alice.id, default_cursor())
      assert Enum.map(statuses, & &1.id) == [s3.id, s2.id, s1.id]
    end

    test "respects max_id (older)", ctx do
      [s1, s2, s3] =
        for _ <- 1..3 do
          s = insert_status!(ctx.bob)
          FeedInsert.enqueue(s.id)
          s
        end

      Oban.drain_queue(queue: :feed)

      # Get the home_feed_entry id for s2 (cursor key — NOT the status id).
      mid = Repo.get_by!(HomeFeedEntry, status_id: s2.id, profile_id: ctx.alice.id).id
      cursor = MastodonCursor.parse(%{"max_id" => Integer.to_string(mid)}, 20, 40)

      {statuses, _} = Timelines.home(ctx.alice.id, cursor)
      ids = Enum.map(statuses, & &1.id)

      assert s1.id in ids
      refute s2.id in ids
      refute s3.id in ids
    end

    test "FeedInsert is idempotent", ctx do
      s = insert_status!(ctx.bob)
      FeedInsert.enqueue(s.id)
      Oban.drain_queue(queue: :feed)
      FeedInsert.enqueue(s.id)
      Oban.drain_queue(queue: :feed)

      assert Repo.aggregate(HomeFeedEntry, :count) == 2
      # 2 because: the author (bob) gets a row too, plus alice. Bob is remote
      # so technically wasted; we'll filter to local-only recipients in the
      # next slice. Not a correctness issue — just a minor write cost.
    end

    test "skips :direct visibility", ctx do
      direct = insert_status!(ctx.bob, %{visibility: :direct})
      FeedInsert.enqueue(direct.id)
      Oban.drain_queue(queue: :feed)

      {statuses, _} = Timelines.home(ctx.alice.id, default_cursor())
      assert statuses == []
    end
  end

  ## Public

  describe "public/2" do
    test "returns public statuses descending across all profiles" do
      alice = local!("alice")
      bob = remote!("bob")

      _s1 = insert_status!(alice)
      _s2 = insert_status!(bob)
      _s3 = insert_status!(alice, %{visibility: :unlisted})

      {statuses, _} = Timelines.public(default_cursor())
      assert length(statuses) == 2
      assert Enum.all?(statuses, &(&1.visibility == :public))
    end

    test "local: true filters to local-only" do
      alice = local!("alice")
      bob = remote!("bob")

      _local = insert_status!(alice)
      _remote = insert_status!(bob)

      {statuses, _} = Timelines.public(default_cursor(), local_only: true)
      assert length(statuses) == 1
      assert hd(statuses).local == true
    end

    test "remote: true filters to remote-only" do
      alice = local!("alice")
      bob = remote!("bob")

      _local = insert_status!(alice)
      _remote = insert_status!(bob)

      {statuses, _} = Timelines.public(default_cursor(), remote_only: true)
      assert length(statuses) == 1
      assert hd(statuses).local == false
    end

    test "deleted statuses excluded" do
      alice = local!("alice")
      s = insert_status!(alice)

      Repo.update_all(
        from(st in Status, where: st.id == ^s.id),
        set: [deleted_at: DateTime.utc_now()]
      )

      assert {[], _} = Timelines.public(default_cursor())
    end
  end

  ## Hashtag

  describe "hashtag/3" do
    test "returns statuses tagged with the given name (case-insensitive)" do
      alice = local!("alice")
      tag = Hashtags.ensure!("photography")
      s = insert_status!(alice)

      Repo.insert!(%StatusHashtag{
        status_id: s.id,
        hashtag_id: tag.id,
        profile_id: alice.id,
        status_visibility: "public",
        inserted_at: DateTime.utc_now()
      })

      {statuses, _} = Timelines.hashtag("Photography", default_cursor())
      assert [%Status{id: id}] = statuses
      assert id == s.id
    end

    test "excludes private/direct statuses" do
      alice = local!("alice")
      tag = Hashtags.ensure!("photography")
      s = insert_status!(alice, %{visibility: :private})

      Repo.insert!(%StatusHashtag{
        status_id: s.id,
        hashtag_id: tag.id,
        profile_id: alice.id,
        status_visibility: "private",
        inserted_at: DateTime.utc_now()
      })

      assert {[], _} = Timelines.hashtag("photography", default_cursor())
    end
  end
end
