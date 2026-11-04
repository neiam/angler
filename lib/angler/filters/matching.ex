defmodule Angler.Filters.Matching do
  @moduledoc """
  Computes the per-viewer filter action for statuses at render time.

  Two sources feed one decision per status:

    * keyword filters (`Angler.Filters.Filter` + keywords) matched against the
      status caption and content warning, and
    * muted hashtags (`Angler.Hashtags.Mute`) matched against the status's tags.

  The strongest action wins (`hide` > `warn` > `blur`). The result threads into
  `AnglerWeb.MastodonAPI.Status`, which drops `hide` matches from list responses
  and stamps a `filtered` marker on `warn`/`blur` matches so every surface — web
  and API — gates filtered content uniformly.

  `context` (one of `home`/`public`/`thread`/`account`/`notifications`) scopes
  which keyword filters apply. `nil` applies every non-expired filter (the
  "filter everywhere" default); hashtag mutes are not context-scoped.
  """

  import Ecto.Query, warn: false

  alias Angler.Filters.Filter
  alias Angler.Hashtags.Muting
  alias Angler.Repo
  alias Angler.Statuses.{Status, StatusHashtag}

  @rank %{"blur" => 1, "warn" => 2, "hide" => 3}

  @type action :: String.t()
  @type match :: %{action: action(), title: String.t()}

  @doc """
  Batched: returns `%{status_id => %{action:, title:}}` for the statuses that
  match. Statuses with no match are absent from the map.
  """
  @spec actions_for(integer() | nil, [Status.t()], String.t() | nil) :: %{integer() => match()}
  def actions_for(nil, _statuses, _context), do: %{}
  def actions_for(_viewer_id, [], _context), do: %{}

  def actions_for(viewer_id, statuses, context) when is_integer(viewer_id) do
    filters = active_filters(viewer_id, context)
    mutes = Muting.action_map(viewer_id)

    if filters == [] and mutes == %{} do
      %{}
    else
      tags = hashtags_by_status(Enum.map(statuses, & &1.id), mutes)

      Enum.reduce(statuses, %{}, fn status, acc ->
        case status_match(status, filters, mutes, tags) do
          nil -> acc
          match -> Map.put(acc, status.id, match)
        end
      end)
    end
  end

  @doc "Single-status convenience wrapping `actions_for/3`."
  @spec action_for(integer() | nil, Status.t(), String.t() | nil) :: match() | nil
  def action_for(viewer_id, %Status{id: id} = status, context) do
    actions_for(viewer_id, [status], context) |> Map.get(id)
  end

  ## Internals

  defp active_filters(viewer_id, context) do
    now = DateTime.utc_now()

    from(f in Filter,
      where: f.profile_id == ^viewer_id,
      where: is_nil(f.expires_at) or f.expires_at > ^now,
      preload: [:keywords]
    )
    |> in_context(context)
    |> Repo.all()
  end

  # No context means every filter applies.
  defp in_context(query, nil), do: query
  defp in_context(query, context), do: where(query, [f], ^context in f.contexts)

  # Only load tags when there is at least one muted tag to match against.
  defp hashtags_by_status(_ids, mutes) when map_size(mutes) == 0, do: %{}

  defp hashtags_by_status(ids, _mutes) do
    Repo.all(
      from sh in StatusHashtag,
        where: sh.status_id in ^ids,
        select: {sh.status_id, sh.hashtag_id}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp status_match(%Status{} = status, filters, mutes, tags) do
    [keyword_match(status, filters), tag_match(status, mutes, tags)]
    |> Enum.reject(&is_nil/1)
    |> strongest()
  end

  defp keyword_match(%Status{} = status, filters) do
    text = String.downcase((status.caption || "") <> " " <> (status.cw_summary || ""))

    filters
    |> Enum.filter(fn f -> Enum.any?(f.keywords, &keyword_hit?(&1, text)) end)
    |> Enum.map(fn f -> %{action: f.filter_action, title: f.title} end)
    |> strongest()
  end

  defp keyword_hit?(%{keyword: kw, whole_word: true}, text) do
    Regex.match?(~r/\b#{Regex.escape(String.downcase(kw))}\b/u, text)
  end

  defp keyword_hit?(%{keyword: kw}, text) do
    String.contains?(text, String.downcase(kw))
  end

  defp tag_match(%Status{id: id}, mutes, tags) when map_size(mutes) > 0 do
    tags
    |> Map.get(id, [])
    |> Enum.flat_map(fn hashtag_id ->
      case Map.get(mutes, hashtag_id) do
        nil -> []
        action -> [%{action: action, title: "muted hashtag"}]
      end
    end)
    |> strongest()
  end

  defp tag_match(_status, _mutes, _tags), do: nil

  # Pick the most-restrictive match from a list (or nil).
  defp strongest([]), do: nil

  defp strongest(matches) when is_list(matches) do
    Enum.max_by(matches, fn %{action: a} -> Map.get(@rank, a, 0) end)
  end
end
