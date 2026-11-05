defmodule Angler.Trends do
  @moduledoc """
  Trends — what's popular over a sliding window. Three feeds:

    * `tags/0` — top hashtags by usage in the last 7 days
    * `statuses/1` — public statuses with the most engagement (favourites +
      reblogs) over the last 7 days
    * `top_tags/2` — most used hashtags today/this week/month/year/ever,
      for the public `/tags` page
    * `links/0` — link cards (we don't have a link-card pipeline yet, so
      this is always `[]`)

  This is a synchronous SQL aggregation; cache it at the controller layer
  later if traffic warrants. Volume is small enough today that a 7-day
  scan over hashtags + statuses is fine.
  """

  import Ecto.Query, warn: false

  alias Angler.Hashtags.Hashtag
  alias Angler.Repo
  alias Angler.Statuses.{Status, StatusHashtag}

  @window_days 7

  @doc "Top trending hashtags by usage over the last #{@window_days} days."
  @spec tags(pos_integer()) :: [
          %{tag: Hashtag.t(), uses: non_neg_integer(), accounts: non_neg_integer()}
        ]
  def tags(limit \\ 10) do
    cutoff = DateTime.add(DateTime.utc_now(), -@window_days * 86_400, :second)

    Repo.all(
      from sh in StatusHashtag,
        join: s in Status,
        on: s.id == sh.status_id and is_nil(s.deleted_at) and s.inserted_at >= ^cutoff,
        join: h in Hashtag,
        on: h.id == sh.hashtag_id,
        group_by: h.id,
        order_by: [desc: count(sh.id), asc: h.name],
        limit: ^limit,
        select: %{
          tag: h,
          uses: count(sh.id),
          accounts: fragment("COUNT(DISTINCT ?)", s.profile_id)
        }
    )
  end

  @periods %{"today" => 1, "week" => 7, "month" => 30, "year" => 365, "all" => nil}

  @doc "The windows `top_tags/2` takes: today, week, month, year, all."
  @spec periods() :: [String.t()]
  def periods, do: ~w(today week month year all)

  @doc """
  Most used hashtags over a window (`"today"` is the last 24 hours, `"all"`
  is all time), for the public `/tags` page. Counts only what a tag page
  would show: public, top-level photo and video posts that aren't deleted,
  on tags that aren't disabled.
  """
  @spec top_tags(String.t(), pos_integer()) :: [
          %{tag: Hashtag.t(), uses: non_neg_integer(), accounts: non_neg_integer()}
        ]
  def top_tags(period, limit \\ 50) when is_map_key(@periods, period) do
    query =
      from sh in StatusHashtag,
        join: s in Status,
        on:
          s.id == sh.status_id and is_nil(s.deleted_at) and s.visibility == :public and
            s.type in ^Status.media_types() and is_nil(s.in_reply_to_id) and
            is_nil(s.in_reply_to_uri),
        join: h in Hashtag,
        on: h.id == sh.hashtag_id and not h.disabled,
        group_by: h.id,
        order_by: [desc: count(sh.id), asc: h.name],
        limit: ^limit,
        select: %{
          tag: h,
          uses: count(sh.id),
          accounts: fragment("COUNT(DISTINCT ?)", s.profile_id)
        }

    query =
      case @periods[period] do
        nil ->
          query

        days ->
          cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
          from [sh, s] in query, where: sh.inserted_at >= ^cutoff
      end

    Repo.all(query)
  end

  @doc """
  Top public top-level statuses by engagement over the last #{@window_days}
  days. `only_media: true` keeps photo and video posts.
  """
  @spec statuses(pos_integer(), keyword()) :: [Status.t()]
  def statuses(limit \\ 20, opts \\ []) do
    cutoff = DateTime.add(DateTime.utc_now(), -@window_days * 86_400, :second)

    base =
      from s in Status,
        where:
          is_nil(s.deleted_at) and
            s.visibility == :public and
            s.inserted_at >= ^cutoff and
            is_nil(s.in_reply_to_id) and is_nil(s.in_reply_to_uri)

    base =
      if opts[:only_media],
        do: from(s in base, where: s.type in ^Status.media_types()),
        else: base

    Repo.all(
      from s in base,
        order_by: [desc: s.likes_count + s.reblogs_count, desc: s.id],
        limit: ^limit,
        preload: [:profile, mentions: :profile, status_hashtags: :hashtag, media_attachments: []]
    )
  end

  @doc "Trending external links. Empty until a link-card pipeline ships."
  @spec links(pos_integer()) :: []
  def links(_limit \\ 10), do: []
end
