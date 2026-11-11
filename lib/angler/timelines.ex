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
        # Photo and video posts only, as upstream; a boost is kept and
        # judged by `photos_reblogs_only` below.
        where: s.type in ^Status.media_types() or not is_nil(h.reblog_id),
        # Replies live in their thread, not the feed (upstream filters
        # `in_reply_to_id`); a boost of one still shows.
        where:
          (is_nil(s.in_reply_to_id) and is_nil(s.in_reply_to_uri)) or not is_nil(h.reblog_id),
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

  @doc """
  Why posts are in `viewer_id`'s home feed: for each status among `items`
  (statuses or boosts) that is there only through a **followed hashtag** —
  the viewer neither wrote it nor follows its author — the names of the
  followed tags it carries. Other statuses are absent from the map.

  Derived from the current follows rather than stored on the feed entry, so it
  answers "why would this be here now". Two queries per call, any page size.
  """
  @spec home_tag_sources(integer(), [Status.t() | Reblog.t()]) :: %{
          optional(integer()) => [String.t()]
        }
  def home_tag_sources(viewer_id, items) when is_integer(viewer_id) do
    statuses = for %Status{} = s <- items, s.profile_id != viewer_id, do: s

    candidates =
      case statuses do
        [] ->
          []

        _ ->
          followed = following_ids(viewer_id)
          for s <- statuses, not MapSet.member?(followed, s.profile_id), do: s.id
      end

    if candidates == [] do
      %{}
    else
      from(sh in StatusHashtag,
        join: f in Angler.Hashtags.Follow,
        on: f.hashtag_id == sh.hashtag_id and f.profile_id == ^viewer_id,
        join: h in Angler.Hashtags.Hashtag,
        on: h.id == sh.hashtag_id,
        where: sh.status_id in ^candidates,
        order_by: [asc: h.name],
        select: {sh.status_id, h.name}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    end
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

    ctx = %{
      viewer_id: viewer_id,
      include?: Keyword.get(opts, :include_reblogs, true),
      photos_only?: Keyword.get(opts, :photos_reblogs_only, false),
      hidden: hidden_author_ids(viewer_id) |> MapSet.new(),
      following: if(ids == [], do: MapSet.new(), else: following_ids(viewer_id))
    }

    Enum.flat_map(rows, fn row ->
      resolve_boost(row, row.reblog_id && Map.get(reblogs, row.reblog_id), ctx)
    end)
  end

  defp resolve_boost(%{status: s} = row, nil, _ctx), do: [Map.put(row, :item, s)]

  defp resolve_boost(%{status: s} = row, reblog, ctx) do
    cond do
      show_boost?(reblog, s, ctx) ->
        [Map.put(row, :item, %{reblog | status: s})]

      s.profile_id == ctx.viewer_id or MapSet.member?(ctx.following, s.profile_id) ->
        [Map.put(row, :item, s)]

      true ->
        []
    end
  end

  defp show_boost?(reblog, s, ctx) do
    ctx.include? and not MapSet.member?(ctx.hidden, reblog.profile_id) and
      (not ctx.photos_only? or media?(s))
  end

  defp media?(%Status{} = s), do: Status.media?(s)

  defp following_ids(viewer_id) do
    Repo.all(
      from f in Angler.Follows.Follower,
        where: f.following_id == ^viewer_id and not is_nil(f.accepted_at),
        select: f.profile_id
    )
    |> MapSet.new()
  end

  @doc """
  Public timeline. Visibility = `:public`, top-level photo and video posts
  only (as upstream's public and network feeds), optionally restricted by
  `local_only` / `remote_only`.
  """
  @spec public(MastodonCursor.cursor(), keyword()) ::
          {[Status.t()], [%{id: integer()}]}
  def public(cursor, opts \\ []) when is_map(cursor) do
    base =
      from s in Status,
        where:
          s.visibility == :public and is_nil(s.deleted_at) and is_nil(s.in_reply_to_id) and
            is_nil(s.in_reply_to_uri)

    base = filter_local(base, opts)
    base = filter_only_media(base, only_media: true)
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

    case Angler.Hashtags.get_by_name(name) do
      nil -> {[], []}
      tag -> hashtag_page(tag.id, cursor, opts)
    end
  end

  # Filtering on the tag *id* (not a join on `hashtags.name`) lets Postgres
  # walk `status_hashtags (hashtag_id, status_id DESC)` in cursor order and stop
  # after one page. Joined by name, the id isn't known when the plan is built,
  # so every post carrying the tag was fetched and sorted for each page.
  #
  # Status must be the FIRST binding: MastodonCursor.apply/3, filter_local/2
  # and filter_only_media/2 all operate on the leading `[s]` binding. Starting
  # from StatusHashtag instead made the cursor compare `max_id` against the
  # join row's PK (a small auto-increment) rather than the status snowflake —
  # so `id < max_id` was always true and the timeline never paginated.
  defp hashtag_page(hashtag_id, cursor, opts) do
    base =
      from s in Status,
        join: sh in StatusHashtag,
        on: sh.status_id == s.id,
        where:
          sh.hashtag_id == ^hashtag_id and s.visibility in [:public, :unlisted] and
            is_nil(s.deleted_at),
        select: s

    base = filter_local(base, opts)
    base = filter_only_media(base, opts)
    base = exclude_authors(base, hidden_author_ids(opts[:viewer_id]))
    base = bound_tag_index(base, cursor)

    statuses =
      base
      |> MastodonCursor.apply(cursor, :id)
      |> Repo.all()
      |> MastodonCursor.finalize_order(cursor, :id)

    {statuses, statuses}
  end

  # The cursor bounds `s.id`; Postgres doesn't carry a range across the join,
  # so repeat it on `sh.status_id` to start the index scan at the page.
  defp bound_tag_index(q, cursor) do
    q = if cursor.max_id, do: where(q, [_s, sh], sh.status_id < ^cursor.max_id), else: q
    q = if cursor.since_id, do: where(q, [_s, sh], sh.status_id > ^cursor.since_id), else: q
    if cursor.min_id, do: where(q, [_s, sh], sh.status_id > ^cursor.min_id), else: q
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
      from [s] in base, where: s.type in ^Status.media_types()
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
