defmodule Angler.Timelines.Workers.HashtagUnfollowPrune do
  @moduledoc """
  Retroactively strip a just-unfollowed hashtag's posts from a user's
  materialized home feed (Pixelfed's `HashtagUnfollowPipeline`).

  `FeedInsert` only stops *future* fan-out; posts already delivered solely
  because the user followed `hashtag_id` would otherwise linger. This worker
  removes a `home_feed_entry` only when the post is there *purely* on the
  strength of that hashtag follow — i.e. the entry is kept if:

    * the author is the viewer, or
    * the viewer directly follows the author (accepted), or
    * the status still carries another hashtag the viewer follows.

  Enqueued from `Angler.Hashtags.Following.unfollow/2` *after* the
  `followed_tags` row is deleted, so the "another followed tag" check no
  longer counts the tag being unfollowed.
  """

  use Oban.Worker, queue: :feed, max_attempts: 5

  import Ecto.Query, warn: false

  alias Angler.Follows.Follower
  alias Angler.Hashtags.Follow, as: HashtagFollow
  alias Angler.Repo
  alias Angler.Statuses.{Status, StatusHashtag}
  alias Angler.Timelines.HomeFeedEntry

  @doc "Enqueue a prune of `hashtag_id` from `profile_id`'s home feed."
  @spec enqueue(integer(), integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(profile_id, hashtag_id)
      when is_integer(profile_id) and is_integer(hashtag_id) do
    %{"profile_id" => profile_id, "hashtag_id" => hashtag_id}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id, "hashtag_id" => hashtag_id}}) do
    # Authors the viewer directly follows (accepted) — their posts stay.
    followed_authors =
      from(f in Follower,
        where: f.following_id == ^profile_id and not is_nil(f.accepted_at),
        select: f.profile_id
      )

    # Hashtags the viewer still follows (the unfollowed one is already gone).
    kept_tags =
      from(f in HashtagFollow, where: f.profile_id == ^profile_id, select: f.hashtag_id)

    # Statuses kept alive by another still-followed tag.
    statuses_with_kept_tag =
      from(sh in StatusHashtag,
        where: sh.hashtag_id in subquery(kept_tags),
        select: sh.status_id
      )

    removable_ids =
      from(hfe in HomeFeedEntry,
        join: sh in StatusHashtag,
        on: sh.status_id == hfe.status_id and sh.hashtag_id == ^hashtag_id,
        join: s in Status,
        on: s.id == hfe.status_id,
        where: hfe.profile_id == ^profile_id,
        where: s.profile_id != ^profile_id,
        where: s.profile_id not in subquery(followed_authors),
        where: hfe.status_id not in subquery(statuses_with_kept_tag),
        select: hfe.id
      )
      |> Repo.all()

    if removable_ids != [] do
      from(hfe in HomeFeedEntry, where: hfe.id in ^removable_ids)
      |> Repo.delete_all()
    end

    :ok
  end
end
