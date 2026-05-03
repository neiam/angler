defmodule Angler.Trends do
  @moduledoc """
  Trends — what's popular over a sliding window. Three feeds:

    * `tags/0` — top hashtags by usage in the last 7 days
    * `statuses/1` — public statuses with the most engagement (favourites +
      reblogs) over the last 7 days
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

  @doc "Top public statuses by engagement over the last #{@window_days} days."
  @spec statuses(pos_integer()) :: [Status.t()]
  def statuses(limit \\ 20) do
    cutoff = DateTime.add(DateTime.utc_now(), -@window_days * 86_400, :second)

    Repo.all(
      from s in Status,
        where:
          is_nil(s.deleted_at) and
            s.visibility == :public and
            s.inserted_at >= ^cutoff,
        order_by: [desc: s.likes_count + s.reblogs_count, desc: s.id],
        limit: ^limit,
        preload: [:profile, mentions: :profile, status_hashtags: :hashtag, media_attachments: []]
    )
  end

  @doc "Trending external links. Empty until a link-card pipeline ships."
  @spec links(pos_integer()) :: []
  def links(_limit \\ 10), do: []
end
