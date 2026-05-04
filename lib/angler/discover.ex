defmodule Angler.Discover do
  @moduledoc """
  Pixelfed `discover/*` aggregations: trending posts, popular accounts,
  trending hashtags. Filters out the viewer's blocks, mutes, and accounts
  they already follow so the feed doesn't echo what they've already seen.

  Photo/video bias is intentional — Pixelfed's discover surface is for
  visual content. Text-only posts are excluded from `trending_posts/2`
  and `for_you/2`; they show up in regular timelines instead.
  """

  import Ecto.Query, warn: false

  alias Angler.Follows.Follower
  alias Angler.Hashtags.Hashtag
  alias Angler.Profiles.{BlocksMutes, Profile}
  alias Angler.Repo
  alias Angler.Statuses.{Status, StatusHashtag}

  @media_types ~w(photo photo:album video video:album)

  ## Posts (Mastodon-shape: GET /api/v1/discover/posts)

  @doc """
  "For you" — recent public photo/video posts the viewer doesn't follow,
  newest-first. Capped at `limit` (default 12, max 40).
  """
  @spec for_you(integer() | nil, pos_integer()) :: [Status.t()]
  def for_you(viewer_id, limit \\ 12) do
    limit = clamp(limit, 1, 40)
    hidden = hidden_profile_ids(viewer_id)

    base =
      from s in Status,
        where:
          s.visibility == :public and is_nil(s.deleted_at) and
            s.is_nsfw == false and s.type in ^@media_types,
        order_by: [desc: s.id],
        limit: ^(limit * 4)

    base
    |> exclude_authors(hidden)
    |> Repo.all()
    |> Enum.take(limit)
    |> preload_for_render()
  end

  ## Trending posts

  @doc "Top public posts by likes_count in `range` (daily | monthly | yearly)."
  @spec trending_posts(integer() | nil, atom()) :: [Status.t()]
  def trending_posts(viewer_id, range \\ :monthly) do
    days =
      case range do
        :daily -> 1
        :monthly -> 31
        :yearly -> 365
        _ -> 31
      end

    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    hidden = hidden_profile_ids(viewer_id)

    base =
      from s in Status,
        where:
          s.visibility == :public and is_nil(s.deleted_at) and
            s.is_nsfw == false and s.type in ^@media_types and
            s.inserted_at >= ^cutoff,
        order_by: [desc: s.likes_count, desc: s.id],
        limit: 30

    base
    |> exclude_authors(hidden)
    |> Repo.all()
    |> preload_for_render()
  end

  ## Popular accounts

  @doc """
  Top public, unlocked accounts by followers_count, excluding viewer +
  accounts viewer already follows. Capped at 16 (Pixelfed convention).
  """
  @spec accounts_popular(integer() | nil, pos_integer()) :: [Profile.t()]
  def accounts_popular(viewer_id, limit \\ 16) do
    base =
      from p in Profile,
        where: p.is_private == false and is_nil(p.status) and is_nil(p.domain),
        order_by: [desc: p.followers_count, asc: p.id],
        limit: 30

    profiles = Repo.all(base)
    follows = if viewer_id, do: viewer_follows(viewer_id), else: MapSet.new()
    hidden = hidden_profile_ids(viewer_id) |> MapSet.new()

    profiles
    |> Enum.reject(fn p ->
      p.id == viewer_id or MapSet.member?(follows, p.id) or MapSet.member?(hidden, p.id)
    end)
    |> Enum.take(limit)
  end

  ## Trending hashtags

  @doc "Top hashtags used in the last 7 days, ordered by usage."
  @spec trending_hashtags(pos_integer()) :: [%{tag: Hashtag.t(), total: non_neg_integer()}]
  def trending_hashtags(limit \\ 9) do
    cutoff = DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)

    Repo.all(
      from sh in StatusHashtag,
        join: s in Status,
        on: s.id == sh.status_id and is_nil(s.deleted_at) and s.visibility == :public,
        join: h in Hashtag,
        on: h.id == sh.hashtag_id and h.disabled == false and h.nsfw == false,
        where: s.inserted_at >= ^cutoff,
        group_by: h.id,
        order_by: [desc: count(sh.id)],
        limit: ^limit,
        select: %{tag: h, total: count(sh.id)}
    )
  end

  ## Internals

  defp hidden_profile_ids(nil), do: []

  defp hidden_profile_ids(viewer_id) do
    Enum.uniq(
      BlocksMutes.block_ids_for(viewer_id) ++
        BlocksMutes.mute_ids_for(viewer_id)
    )
  end

  defp exclude_authors(q, []), do: q

  defp exclude_authors(q, ids) do
    from [s] in q, where: s.profile_id not in ^ids
  end

  defp viewer_follows(viewer_id) do
    Repo.all(
      from f in Follower,
        where: f.following_id == ^viewer_id and not is_nil(f.accepted_at),
        select: f.profile_id
    )
    |> MapSet.new()
  end

  defp preload_for_render(rows) do
    Repo.preload(rows,
      profile: [],
      mentions: :profile,
      status_hashtags: :hashtag,
      media_attachments: []
    )
  end

  defp clamp(n, lo, _hi) when n < lo, do: lo
  defp clamp(n, _lo, hi) when n > hi, do: hi
  defp clamp(n, _, _), do: n
end
