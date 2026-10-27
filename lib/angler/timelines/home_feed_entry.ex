defmodule Angler.Timelines.HomeFeedEntry do
  @moduledoc """
  Materialized home-timeline entry. One row per `(viewer, status)`.

  See `plans/timelines/models/home_feed_entry.md`. The `id` is a bigserial
  (NOT a snowflake) — its only purpose is to drive Mastodon-cursor pagination
  on the viewer's feed.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "home_feed_entries" do
    belongs_to :profile, Angler.Profiles.Profile, type: :integer
    belongs_to :status, Angler.Statuses.Status, type: :integer
    # Set when a boost put the status here; the feed shows it as that boost.
    belongs_to :reblog, Angler.Reblogs.Reblog
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
