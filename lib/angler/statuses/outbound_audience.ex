defmodule Angler.Statuses.OutboundAudience do
  @moduledoc """
  Compute the unique remote inbox URLs that should receive an outbound
  status delivery.

  Per ActivityPub:
    * `:public` / `:unlisted` — fan to followers' shared inboxes (or
      personal inboxes when no shared inbox is known).
    * `:private` — same as above (followers only) but the activity carries
      the followers collection as `to`.
    * `:direct` — only the mentioned remote actors.

  Local recipients don't appear here — they're handled by the home-feed
  fan-out worker (`Angler.Timelines.Workers.FeedInsert`).

  Returns a deduped list of URLs.
  """

  import Ecto.Query, warn: false

  alias Angler.Follows.Follower
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses.{Mention, Status}

  @spec inboxes_for(Status.t()) :: [String.t()]
  def inboxes_for(%Status{visibility: :direct, id: status_id}) do
    from(m in Mention,
      where: m.status_id == ^status_id,
      join: p in Profile,
      on: p.id == m.profile_id,
      where: not is_nil(p.domain),
      select: %{inbox: p.inbox_url, shared: p.shared_inbox_url}
    )
    |> Repo.all()
    |> dedupe_inboxes()
  end

  def inboxes_for(%Status{profile_id: author_id}) do
    # Followers of the author who are remote (have a domain).
    from(f in Follower,
      where: f.profile_id == ^author_id and not is_nil(f.accepted_at),
      join: p in Profile,
      on: p.id == f.following_id,
      where: not is_nil(p.domain),
      select: %{inbox: p.inbox_url, shared: p.shared_inbox_url}
    )
    |> Repo.all()
    |> dedupe_inboxes()
  end

  ## Internals

  # Prefer sharedInbox where present (one delivery per remote instance is
  # what every grown federation instance does). Fall back to the per-actor
  # inbox when no shared inbox is known.
  defp dedupe_inboxes(rows) do
    rows
    |> Enum.map(fn %{inbox: i, shared: s} -> s || i end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
