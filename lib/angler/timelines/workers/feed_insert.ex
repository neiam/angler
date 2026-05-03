defmodule Angler.Timelines.Workers.FeedInsert do
  @moduledoc """
  Fan a status into followers' `home_feed_entries`.

  Triggered after status creation (local or inbound). Skips `:direct`
  statuses (those go to participants only via the DM grouping). Idempotent
  — `INSERT ... ON CONFLICT DO NOTHING` against the `(profile_id, status_id)`
  unique.

  Visibility rules:
    * `:public`, `:unlisted`, `:private` — fan to all followers (status
      visibility filtering happens at the *read* layer in `Statuses.visible_to?/2`,
      not at fan-out time, so changes to a viewer's follow state take
      immediate effect).
    * `:direct` — no fan-out.

  See `plans/timelines/queues/feed_insert_pipeline.md`.
  """

  use Oban.Worker,
    queue: :feed,
    max_attempts: 5,
    unique: [period: 60, fields: [:args], keys: [:status_id]]

  import Ecto.Query, warn: false

  alias Angler.Follows.Follower
  alias Angler.Repo
  alias Angler.Statuses.Status
  alias Angler.Timelines.HomeFeedEntry

  @doc "Enqueue a fan-out job for `status_id`."
  @spec enqueue(integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(status_id) when is_integer(status_id) do
    %{"status_id" => status_id}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"status_id" => status_id}}) do
    case Repo.get(Status, status_id) do
      nil ->
        :ok

      %Status{visibility: :direct} ->
        :ok

      %Status{} = status ->
        fan_out(status)
    end
  end

  defp fan_out(%Status{id: status_id, profile_id: author_id, inserted_at: inserted_at}) do
    # Followers of the author. Includes the author themselves so their own
    # statuses show up in their home timeline (Mastodon behaviour).
    follower_ids =
      from(f in Follower,
        where: f.profile_id == ^author_id and not is_nil(f.accepted_at),
        select: f.following_id
      )
      |> Repo.all()

    recipient_ids = Enum.uniq([author_id | follower_ids])

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
end
