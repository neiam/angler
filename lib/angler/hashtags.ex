defmodule Angler.Hashtags do
  @moduledoc """
  Hashtag lookup + upsert.

  Names are stored lower-cased. `slug` is currently a copy of `name` —
  Pixelfed strips diacritics and other non-ASCII into a slug; we'll port
  that mapping when search lands.
  """

  import Ecto.Query, warn: false
  alias Angler.Hashtags.CountCache
  alias Angler.Hashtags.Hashtag
  alias Angler.Repo
  alias Angler.Statuses.Status
  alias Angler.Statuses.StatusHashtag

  # `usage_count` on the row is vestigial (it's never incremented), so display
  # counts are computed live from `status_hashtags`, for just the tags a caller
  # asks about, and cached per tag in `Angler.Hashtags.CountCache`. A count is
  # therefore stale by at most the TTL below (60s) after a post is created or
  # deleted.
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
  Live usage counts (public/unlisted, non-deleted posts) for the tag `names`,
  keyed by lower-cased name. Every requested name is in the result (0 if unused).

  Cached per tag for #{div(@count_cache_ttl_ms, 1000)}s; the uncached names are
  counted together in one query.
  """
  @spec usage_counts([String.t()]) :: %{optional(String.t()) => non_neg_integer()}
  def usage_counts(names) when is_list(names) do
    names = names |> Enum.map(&normalize/1) |> Enum.uniq()
    now = System.monotonic_time(:millisecond)
    cached = CountCache.fresh(names, now)

    case Enum.reject(names, &Map.has_key?(cached, &1)) do
      [] ->
        cached

      missing ->
        counted = compute_usage_counts(missing)
        :ok = CountCache.put(counted, now + @count_cache_ttl_ms)
        Map.merge(cached, counted)
    end
  end

  @doc "Live usage count for a single tag name (0 if unused). See `usage_counts/1`."
  @spec usage_count(String.t()) :: non_neg_integer()
  def usage_count(name) when is_binary(name) do
    key = normalize(name)
    Map.fetch!(usage_counts([key]), key)
  end

  @doc "Drop the cached usage counts so the next read recomputes."
  @spec clear_usage_counts_cache() :: :ok
  def clear_usage_counts_cache, do: CountCache.clear()

  defp normalize(name), do: name |> String.trim_leading("#") |> String.downcase()

  defp compute_usage_counts(names) do
    counted =
      Repo.all(
        from h in Hashtag,
          join: sh in StatusHashtag,
          on: sh.hashtag_id == h.id,
          join: s in Status,
          on:
            s.id == sh.status_id and is_nil(s.deleted_at) and
              s.visibility in [:public, :unlisted],
          where: h.name in ^names,
          group_by: h.name,
          select: {h.name, count(sh.id)}
      )
      |> Map.new()

    Map.new(names, &{&1, Map.get(counted, &1, 0)})
  end
end
