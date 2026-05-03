defmodule Angler.Filters do
  @moduledoc """
  Per-user keyword filters. Mastodon v2 shape — clients fetch the filter
  list and apply matching locally; we don't currently strip filtered status
  content server-side.
  """

  import Ecto.Query, warn: false

  alias Angler.Filters.Filter
  alias Angler.Filters.Keyword, as: FilterKeyword
  alias Angler.Repo

  @spec list(integer()) :: [Filter.t()]
  def list(profile_id) when is_integer(profile_id) do
    Repo.all(
      from f in Filter,
        where: f.profile_id == ^profile_id,
        order_by: [desc: f.id],
        preload: [:keywords]
    )
  end

  @spec get(integer(), integer()) :: Filter.t() | nil
  def get(profile_id, id) do
    Filter
    |> Repo.get_by(id: id, profile_id: profile_id)
    |> case do
      nil -> nil
      f -> Repo.preload(f, :keywords)
    end
  end

  @spec create(integer(), map()) :: {:ok, Filter.t()} | {:error, Ecto.Changeset.t()}
  def create(profile_id, attrs) when is_integer(profile_id) do
    keywords = parse_keywords(attrs["keywords_attributes"])
    attrs = Map.put(attrs, "profile_id", profile_id)

    Repo.transaction(fn ->
      {:ok, filter} = %Filter{} |> Filter.changeset(attrs) |> Repo.insert()
      Enum.each(keywords, fn kw -> insert_keyword!(filter.id, kw) end)
      Repo.preload(filter, :keywords, force: true)
    end)
  end

  @spec update(Filter.t(), map()) :: {:ok, Filter.t()} | {:error, Ecto.Changeset.t()}
  def update(%Filter{} = filter, attrs) do
    keywords_attrs = parse_keywords(attrs["keywords_attributes"])

    Repo.transaction(fn ->
      {:ok, updated} = filter |> Filter.changeset(attrs) |> Repo.update()

      if keywords_attrs != [] do
        # Replace-all semantics for simplicity. Mastodon supports per-keyword
        # patches via _destroy + id; we'll add when clients ask for it.
        Repo.delete_all(from k in FilterKeyword, where: k.filter_id == ^filter.id)
        Enum.each(keywords_attrs, fn kw -> insert_keyword!(filter.id, kw) end)
      end

      Repo.preload(updated, :keywords, force: true)
    end)
  end

  @spec delete(Filter.t()) :: :ok
  def delete(%Filter{} = filter) do
    Repo.delete!(filter)
    :ok
  end

  ## Internals

  defp parse_keywords(nil), do: []
  defp parse_keywords([]), do: []

  defp parse_keywords(list) when is_list(list) do
    Enum.flat_map(list, fn
      %{"keyword" => k} = m when is_binary(k) ->
        [%{keyword: k, whole_word: truthy?(m["whole_word"])}]

      _ ->
        []
    end)
  end

  defp parse_keywords(_), do: []

  defp insert_keyword!(filter_id, %{keyword: kw, whole_word: ww}) do
    %{filter_id: filter_id, keyword: kw, whole_word: ww}
    |> FilterKeyword.changeset()
    |> Repo.insert!()
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false
end
