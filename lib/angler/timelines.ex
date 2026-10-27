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
  alias Angler.Profiles.BlocksMutes
  alias Angler.Reblogs.Reblog
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
  @spec home(integer(), MastodonCursor.cursor(), keyword()) ::
          {[Status.t() | Reblog.t()], [%{id: integer()}]}
  def home(viewer_id, cursor, opts \\ []) when is_integer(viewer_id) and is_map(cursor) do
    base =
      from h in HomeFeedEntry,
        where: h.profile_id == ^viewer_id,
        join: s in Status,
        on: s.id == h.status_id and is_nil(s.deleted_at),
        select: %{id: h.id, status: s, reblog_id: h.reblog_id}

    rows =
      base
      |> MastodonCursor.apply(cursor, :id)
      |> Repo.all()
      |> MastodonCursor.finalize_order(cursor, :id)
      |> apply_viewer_filters(viewer_id)
      |> resolve_boosts(viewer_id, opts)

    statuses = Enum.map(rows, & &1.item)
    cursor_rows = Enum.map(rows, &%{id: &1.id})

    {statuses, cursor_rows}
  end

  # An entry a boost put here is shown as that boost (`%Reblog{}` with the
  # booster and the status loaded), which the renderer turns into a
  # wrapper. With boosts off (`include_reblogs: false`), or for a booster
  # the viewer blocks or mutes, it falls back to the plain post if the
  # viewer would have it anyway (follows the author, or wrote it) and is
  # dropped otherwise. `photos_reblogs_only` keeps only boosts of media.
  defp resolve_boosts(rows, viewer_id, opts) do
    ids = for %{reblog_id: id} when is_integer(id) <- rows, do: id

    reblogs =
      if ids == [],
        do: %{},
        else:
          Repo.all(from r in Reblog, where: r.id in ^ids, preload: :profile)
          |> Map.new(&{&1.id, &1})

    include? = Keyword.get(opts, :include_reblogs, true)
    photos_only? = Keyword.get(opts, :photos_reblogs_only, false)
    hidden = hidden_author_ids(viewer_id) |> MapSet.new()
    following = if ids == [], do: MapSet.new(), else: following_ids(viewer_id)

    Enum.flat_map(rows, fn %{status: s} = row ->
      reblog = row.reblog_id && Map.get(reblogs, row.reblog_id)

      show_boost? =
        reblog != nil and include? and not MapSet.member?(hidden, reblog.profile_id) and
          (not photos_only? or media?(s))

      cond do
        reblog == nil ->
          [Map.put(row, :item, s)]

        show_boost? ->
          [Map.put(row, :item, %{reblog | status: s})]

        s.profile_id == viewer_id or MapSet.member?(following, s.profile_id) ->
          [Map.put(row, :item, s)]

        true ->
          []
      end
    end)
  end

  defp media?(%Status{type: type}), do: type in ~w(photo photo:album video video:album)

  defp following_ids(viewer_id) do
    Repo.all(
      from f in Angler.Follows.Follower,
        where: f.following_id == ^viewer_id and not is_nil(f.accepted_at),
        select: f.profile_id
    )
    |> MapSet.new()
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
    base = exclude_authors(base, hidden_author_ids(opts[:viewer_id]))

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

    # Status must be the FIRST binding: MastodonCursor.apply/3, filter_local/2
    # and filter_only_media/2 all operate on the leading `[s]` binding. Starting
    # from StatusHashtag instead made the cursor compare `max_id` against the
    # join row's PK (a small auto-increment) rather than the status snowflake —
    # so `id < max_id` was always true and the timeline never paginated.
    base =
      from s in Status,
        join: sh in StatusHashtag,
        on: sh.status_id == s.id,
        join: h in Angler.Hashtags.Hashtag,
        on: h.id == sh.hashtag_id,
        where: h.name == ^name and s.visibility in [:public, :unlisted] and is_nil(s.deleted_at),
        select: s

    base = filter_local(base, opts)
    base = filter_only_media(base, opts)
    base = exclude_authors(base, hidden_author_ids(opts[:viewer_id]))

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

  defp apply_viewer_filters(rows, viewer_id) do
    hidden = hidden_author_ids(viewer_id) |> MapSet.new()

    if MapSet.size(hidden) == 0 do
      rows
    else
      Enum.reject(rows, fn %{status: s} -> MapSet.member?(hidden, s.profile_id) end)
    end
  end

  defp hidden_author_ids(nil), do: []

  defp hidden_author_ids(viewer_id) when is_integer(viewer_id) do
    Enum.uniq(BlocksMutes.block_ids_for(viewer_id) ++ BlocksMutes.mute_ids_for(viewer_id))
  end

  defp exclude_authors(query, []), do: query

  defp exclude_authors(query, ids) when is_list(ids) do
    from [s] in query, where: s.profile_id not in ^ids
  end
end
