defmodule Angler.Hashtags do
  @moduledoc """
  Hashtag lookup + upsert.

  Names are stored lower-cased. `slug` is currently a copy of `name` —
  Pixelfed strips diacritics and other non-ASCII into a slug; we'll port
  that mapping when search lands.
  """

  import Ecto.Query, warn: false
  alias Angler.Hashtags.Hashtag
  alias Angler.Repo
  alias Angler.Statuses.Status
  alias Angler.Statuses.StatusHashtag

  # `usage_count` on the row is vestigial (it's never incremented), so display
  # counts are computed live from `status_hashtags`. The aggregation is cached
  # as a single `name => count` map in `:persistent_term` (same convention as
  # `Angler.Instance.stats/0`): one grouped query per TTL window, O(1) lookups
  # in between. A count is therefore stale by at most the TTL below (60s) after
  # a post is created or deleted.
  @count_cache_key {__MODULE__, :usage_counts}
  @count_cache_ttl_ms 60_000

  @doc "Get a hashtag by name (case-insensitive). Returns nil if missing."
  @spec get_by_name(String.t()) :: Hashtag.t() | nil
  def get_by_name(name) when is_binary(name) do
    Repo.get_by(Hashtag, name: String.downcase(name))
  end

  @doc "Find or create a hashtag by name (case-insensitive)."
  @spec ensure!(String.t()) :: Hashtag.t()
  def ensure!(name) when is_binary(name) do
    name = String.downcase(name)

    case Repo.get_by(Hashtag, name: name) do
      %Hashtag{} = tag ->
        tag

      nil ->
        %{name: name, slug: name}
        |> Hashtag.changeset()
        |> Repo.insert(on_conflict: :nothing, conflict_target: :name)
        |> case do
          {:ok, %Hashtag{id: id}} when is_integer(id) -> Repo.get!(Hashtag, id)
          # Race: another process created the row between our SELECT and INSERT.
          {:ok, _} -> Repo.get_by!(Hashtag, name: name)
          {:error, _} -> Repo.get_by!(Hashtag, name: name)
        end
    end
  end

  @doc """
  Live usage counts (public/unlisted, non-deleted posts) keyed by hashtag name.

  Cached in `:persistent_term` for #{div(@count_cache_ttl_ms, 1000)}s. Tags with
  no qualifying posts are absent from the map (callers default to 0).
  """
  @spec usage_counts() :: %{optional(String.t()) => non_neg_integer()}
  def usage_counts do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@count_cache_key, :miss) do
      {value, expires_at} when is_integer(expires_at) and expires_at > now ->
        value

      _ ->
        value = compute_usage_counts()
        :persistent_term.put(@count_cache_key, {value, now + @count_cache_ttl_ms})
        value
    end
  end

  @doc "Live usage count for a single tag name (0 if unused). Cached via `usage_counts/0`."
  @spec usage_count(String.t()) :: non_neg_integer()
  def usage_count(name) when is_binary(name) do
    key = name |> String.trim_leading("#") |> String.downcase()
    Map.get(usage_counts(), key, 0)
  end

  @doc "Drop the cached usage-count map so the next read recomputes."
  @spec clear_usage_counts_cache() :: :ok
  def clear_usage_counts_cache do
    :persistent_term.erase(@count_cache_key)
    :ok
  end

  defp compute_usage_counts do
    Repo.all(
      from sh in StatusHashtag,
        join: s in Status,
        on:
          s.id == sh.status_id and is_nil(s.deleted_at) and s.visibility in [:public, :unlisted],
        join: h in Hashtag,
        on: h.id == sh.hashtag_id,
        group_by: h.name,
        select: {h.name, count(sh.id)}
    )
    |> Map.new()
  end
end
