defmodule Angler.Search do
  @moduledoc """
  Unified search over accounts, hashtags, and statuses.

  Backs both the Mastodon `GET /api/v2/search` endpoint
  (`AnglerWeb.MastodonAPI.SearchController`) and the web frontend
  (`AnglerWeb.SearchLive` + the navbar type-ahead). Each function returns raw
  schema structs; callers are responsible for rendering them (Mastodon JSON,
  HEEx, etc.).

  Matching is `ilike`-based — a prefix match for accounts and hashtags, a
  substring match for status captions. There's no full-text index yet; this is
  good enough for the current slice and can be swapped for `pg_trgm` or an
  external engine (Tantivy/OpenSearch) later without touching callers.
  """

  import Ecto.Query, only: [from: 2]

  alias Angler.Hashtags.Hashtag
  alias Angler.Profiles
  alias Angler.Repo
  alias Angler.Statuses.Status

  @default_limit 20
  @max_limit 40

  @status_preloads [
    :profile,
    {:mentions, :profile},
    {:status_hashtags, :hashtag},
    :media_attachments
  ]

  @doc """
  Search all three buckets at once.

  `viewer_id` scopes status visibility (the viewer always sees their own
  non-public posts); pass `nil` for an anonymous viewer. Options are forwarded
  to the per-bucket functions (currently just `:limit`).
  """
  @spec all(String.t(), integer() | nil, keyword()) :: %{
          accounts: [struct()],
          hashtags: [struct()],
          statuses: [struct()]
        }
  def all(query, viewer_id, opts \\ []) when is_binary(query) do
    %{
      accounts: accounts(query, opts),
      hashtags: hashtags(query, opts),
      statuses: statuses(query, viewer_id, opts)
    }
  end

  @doc "Accounts whose username or display name prefix-matches `query`."
  @spec accounts(String.t(), keyword()) :: [struct()]
  def accounts(query, opts \\ []) when is_binary(query) do
    if blank?(query), do: [], else: Profiles.search(query, limit: limit(opts))
  end

  @doc "Hashtags whose name prefix-matches `query` (a leading `#` is ignored)."
  @spec hashtags(String.t(), keyword()) :: [struct()]
  def hashtags(query, opts \\ []) when is_binary(query) do
    pattern = query |> String.trim() |> String.trim_leading("#") |> String.downcase()

    if pattern == "" do
      []
    else
      Repo.all(
        from h in Hashtag,
          where: h.disabled == false and ilike(h.name, ^(pattern <> "%")),
          order_by: [desc: h.usage_count, asc: h.name],
          limit: ^limit(opts)
      )
    end
  end

  @doc """
  Statuses whose caption matches `query`. Returns the viewer's own posts plus
  any public/unlisted post (local or remote). Associations needed for
  rendering are preloaded.
  """
  @spec statuses(String.t(), integer() | nil, keyword()) :: [struct()]
  def statuses(query, viewer_id, opts \\ []) when is_binary(query) do
    if blank?(query) do
      []
    else
      pattern = "%" <> String.trim(query) <> "%"

      Repo.all(
        from s in Status,
          where:
            is_nil(s.deleted_at) and
              ilike(s.caption, ^pattern) and
              (s.visibility in [:public, :unlisted] or s.profile_id == ^(viewer_id || -1)),
          order_by: [desc: s.id],
          limit: ^limit(opts),
          preload: ^@status_preloads
      )
    end
  end

  @doc "Clamp a caller-supplied limit into the supported range."
  @spec clamp_limit(integer()) :: integer()
  def clamp_limit(n) when is_integer(n), do: n |> max(1) |> min(@max_limit)

  defp limit(opts), do: opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()

  defp blank?(query), do: String.trim(query) == ""
end
