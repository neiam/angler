defmodule Angler.Timelines.Workers.FeedInsert do
  @moduledoc """
  Fan a status into followers' `home_feed_entries`.

  Triggered after status creation (local or inbound). Skips `:direct`
  statuses (those go to participants only via the DM grouping) and replies
  (those show in their thread, not the feed, as upstream). Idempotent
  — `INSERT ... ON CONFLICT DO NOTHING` against the `(profile_id, status_id)`
  unique.

  Visibility rules:
    * `:public`, `:unlisted`, `:private` — fan to all of the author's
      followers (status visibility filtering happens at the *read* layer,
      not at fan-out time, so changes to a viewer's follow state take
      immediate effect).
    * `:public`, `:unlisted` — *also* fan to anyone following a hashtag the
      status carries (Mastodon followed-tags / Pixelfed hashtag-follow).
      Restricted to public + unlisted because the home read path does no
      visibility filtering, so this is the enforcement point — a `:private`
      post must never reach a hashtag-follower who isn't an actual follower.
    * `:direct` — no fan-out.

  ## Reblog (boost) fan-out

  A boost re-shares an existing status into the **booster's** audience. When
  `enqueue_reblog/2` is used, the original status is fanned into the booster's
  followers' feeds (plus the booster themselves), keyed on the *booster* rather
  than the original author. Any existing `home_feed_entry` for those recipients
  is dropped first so the re-inserted row gets a fresh (higher) bigserial `id`
  and an updated `inserted_at` — the boosted post surfaces at the top of the
  timeline as if it were new. Only `:public` / `:unlisted` statuses are eligible
  (the read path does no visibility filtering).

  See `plans/timelines/queues/feed_insert_pipeline.md`.
  """

  use Oban.Worker,
    queue: :feed,
    max_attempts: 5,
    unique: [period: 60, fields: [:args], keys: [:status_id, :reblog_actor_id]]

  import Ecto.Query, warn: false

  alias Angler.Follows.Follower
  alias Angler.Hashtags.Follow, as: HashtagFollow
  alias Angler.Repo
  alias Angler.Statuses.{Status, StatusHashtag}
  alias Angler.Timelines.HomeFeedEntry

  @doc "Enqueue a fan-out job for `status_id`."
  @spec enqueue(integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(status_id) when is_integer(status_id) do
    %{"status_id" => status_id}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @doc """
  Enqueue a reblog (boost) fan-out: fan `status_id` into `actor_id`'s
  followers' feeds (plus `actor_id`), bumped to the top of the timeline.
  """
  @spec enqueue_reblog(integer(), integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_reblog(status_id, actor_id)
      when is_integer(status_id) and is_integer(actor_id) do
    %{"status_id" => status_id, "reblog_actor_id" => actor_id}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"status_id" => status_id, "reblog_actor_id" => actor_id}})
      when is_integer(actor_id) do
    case Repo.get(Status, status_id) do
      nil ->
        :ok

      %Status{visibility: vis} when vis in [:private, :direct] ->
        :ok

      %Status{} = status ->
        fan_out_reblog(status, actor_id)
    end
  end

  def perform(%Oban.Job{args: %{"status_id" => status_id}}) do
    case Repo.get(Status, status_id) do
      nil ->
        :ok

      %Status{visibility: :direct} ->
        :ok

      %Status{in_reply_to_id: parent} when not is_nil(parent) ->
        :ok

      %Status{} = status ->
        fan_out(status)
    end
  end

  defp fan_out(%Status{id: status_id, profile_id: author_id, inserted_at: inserted_at} = status) do
    # Followers of the author. Includes the author themselves so their own
    # statuses show up in their home timeline (Mastodon behaviour).
    follower_ids =
      from(f in Follower,
        where: f.profile_id == ^author_id and not is_nil(f.accepted_at),
        select: f.following_id
      )
      |> Repo.all()

    recipient_ids = Enum.uniq([author_id | follower_ids] ++ hashtag_follower_ids(status))

    rows =
      Enum.map(recipient_ids, fn rid ->
        %{
          profile_id: rid,
          status_id: status_id,
          inserted_at: inserted_at || DateTime.utc_now()
        }
      end)

    if rows != [] do
      Repo.insert_all(HomeFeedEntry, rows,
        on_conflict: :nothing,
        conflict_target: [:profile_id, :status_id]
      )
    end

    :ok
  end

  # Boost fan-out: re-share `status` into the booster's audience, surfacing it
  # at the top of each recipient's timeline. We delete any pre-existing entry
  # for these recipients first so the re-inserted row earns a fresh bigserial
  # `id` (timeline order) and a current `inserted_at` (reads as "new").
  defp fan_out_reblog(%Status{id: status_id}, actor_id) do
    reblog_id =
      Repo.one(
        from r in Angler.Reblogs.Reblog,
          where: r.profile_id == ^actor_id and r.status_id == ^status_id,
          select: r.id
      )

    follower_ids =
      from(f in Follower,
        where: f.profile_id == ^actor_id and not is_nil(f.accepted_at),
        select: f.following_id
      )
      |> Repo.all()

    recipient_ids = Enum.uniq([actor_id | follower_ids])

    from(h in HomeFeedEntry,
      where: h.status_id == ^status_id and h.profile_id in ^recipient_ids
    )
    |> Repo.delete_all()

    now = DateTime.utc_now()

    rows =
      Enum.map(recipient_ids, fn rid ->
        %{profile_id: rid, status_id: status_id, reblog_id: reblog_id, inserted_at: now}
      end)

    if rows != [] do
      Repo.insert_all(HomeFeedEntry, rows,
        on_conflict: :nothing,
        conflict_target: [:profile_id, :status_id]
      )
    end

    :ok
  end

  # Profiles following any hashtag this status carries. Only public/unlisted
  # statuses are eligible (see moduledoc). The `(profile_id, status_id)`
  # conflict target dedups a profile who both follows the author and a
  # matching tag, so we don't pre-filter against the author's followers here.
  defp hashtag_follower_ids(%Status{id: status_id, visibility: vis})
       when vis in [:public, :unlisted] do
    from(sh in StatusHashtag,
      where: sh.status_id == ^status_id,
      join: f in HashtagFollow,
      on: f.hashtag_id == sh.hashtag_id,
      select: f.profile_id,
      distinct: true
    )
    |> Repo.all()
  end

  defp hashtag_follower_ids(%Status{}), do: []
end
