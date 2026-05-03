defmodule Angler.Timelines do
  @moduledoc """
  Read-side timeline queries: home (materialized), public, hashtag.

  Mute / block / domain-block read-time filters are stubbed (those tables
  don't exist yet — they'll be wired in once the accounts grouping ships).
  Their seam lives in `apply_viewer_filters/2`.

  See `plans/timelines/`.
  """

  import Ecto.Query, warn: false

  alias Angler.Pagination.MastodonCursor
  alias Angler.Repo
  alias Angler.Statuses.{Status, StatusHashtag}
  alias Angler.Timelines.HomeFeedEntry

  @doc """
  Home timeline rows for `viewer_id`.

  Returns `{statuses, cursor_rows}` — the second element is what the
  controller passes to `MastodonCursor.link_header/3`. Cursor pagination is
  on the **`home_feed_entries.id`** (bigserial), not on the snowflake
  status_id, so users with many follows get monotonic-time-ish paging even
  when an old status is fanned in late.
  """
  @spec home(integer(), MastodonCursor.cursor()) ::
          {[Status.t()], [%{id: integer()}]}
  def home(viewer_id, cursor) when is_integer(viewer_id) and is_map(cursor) do
    base =
      from h in HomeFeedEntry,
        where: h.profile_id == ^viewer_id,
        join: s in Status,
        on: s.id == h.status_id and is_nil(s.deleted_at),
        select: %{id: h.id, status: s}

    rows =
      base
      |> MastodonCursor.apply(cursor, :id)
      |> Repo.all()
      |> MastodonCursor.finalize_order(cursor, :id)
      |> apply_viewer_filters(viewer_id)

    statuses = Enum.map(rows, & &1.status)
    cursor_rows = Enum.map(rows, &%{id: &1.id})

    {statuses, cursor_rows}
  end

  @doc """
  Public timeline. Visibility = `:public`, optionally restricted by
  `local_only` / `remote_only` / `only_media`.
  """
  @spec public(MastodonCursor.cursor(), keyword()) ::
          {[Status.t()], [%{id: integer()}]}
  def public(cursor, opts \\ []) when is_map(cursor) do
    base =
      from s in Status,
        where: s.visibility == :public and is_nil(s.deleted_at)

    base = filter_local(base, opts)
    base = filter_only_media(base, opts)

    statuses =
      base
      |> MastodonCursor.apply(cursor, :id)
      |> Repo.all()
      |> MastodonCursor.finalize_order(cursor, :id)

    {statuses, statuses}
  end

  @doc """
  Hashtag timeline.

  Tag name comparison is case-insensitive (citext) so `#Photo` matches
  `#photo`.
  """
  @spec hashtag(String.t(), MastodonCursor.cursor(), keyword()) ::
          {[Status.t()], [%{id: integer()}]}
  def hashtag(name, cursor, opts \\ []) when is_binary(name) and is_map(cursor) do
    name = name |> String.downcase() |> String.trim_leading("#")

    base =
      from sh in StatusHashtag,
        join: s in Status,
        on: s.id == sh.status_id and is_nil(s.deleted_at),
        join: h in Angler.Hashtags.Hashtag,
        on: h.id == sh.hashtag_id,
        where: h.name == ^name and s.visibility in [:public, :unlisted],
        select: s

    base = filter_local(base, opts)
    base = filter_only_media(base, opts)

    statuses =
      base
      |> MastodonCursor.apply(cursor, :id)
      |> Repo.all()
      |> MastodonCursor.finalize_order(cursor, :id)

    {statuses, statuses}
  end

  ## Internals

  defp filter_local(base, opts) do
    cond do
      opts[:local_only] -> from [s] in base, where: s.local == true
      opts[:remote_only] -> from [s] in base, where: s.local == false
      true -> base
    end
  end

  defp filter_only_media(base, opts) do
    if opts[:only_media] do
      # We don't have a media table yet; treat `type` containing "photo" or
      # "video" as the proxy. Once the media slice lands, switch to a join
      # against `media`.
      from [s] in base, where: s.type in ["photo", "photo:album", "video", "video:album"]
    else
      base
    end
  end

  # Stub for mute / block / user_domain_block filtering. Once those tables
  # exist this is where we'll plug them in. Today: pass-through.
  defp apply_viewer_filters(rows, _viewer_id), do: rows
end
