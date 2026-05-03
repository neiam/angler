defmodule AnglerWeb.MastodonAPI.Poll do
  @moduledoc """
  Mastodon-shaped `Poll` JSON object. Embedded in `Status.poll` and returned
  from `GET /api/v1/polls/:id`.
  """

  alias Angler.Polls
  alias Angler.Polls.Poll
  alias Angler.Polls.Option

  @spec render(Poll.t(), integer() | nil) :: map()
  def render(%Poll{} = poll, viewer_id \\ nil) do
    expired? = Polls.expired?(poll)
    voted_ids = if viewer_id, do: Polls.voted_option_ids(poll.id, viewer_id), else: []
    options = Enum.sort_by(poll.options, & &1.position)

    %{
      "id" => Integer.to_string(poll.id),
      "expires_at" => DateTime.to_iso8601(poll.expires_at),
      "expired" => expired?,
      "multiple" => poll.multiple,
      "votes_count" => Enum.reduce(options, 0, fn o, acc -> acc + o.votes_count end),
      "voters_count" => poll.voters_count,
      "voted" => voted_ids != [],
      "own_votes" => own_vote_indices(options, voted_ids),
      "options" => Enum.map(options, &render_option(&1, poll))
    }
  end

  defp render_option(%Option{} = o, %Poll{hide_totals: true} = poll) do
    if Polls.expired?(poll) do
      %{"title" => o.title, "votes_count" => o.votes_count}
    else
      %{"title" => o.title, "votes_count" => nil}
    end
  end

  defp render_option(%Option{} = o, %Poll{}) do
    %{"title" => o.title, "votes_count" => o.votes_count}
  end

  defp own_vote_indices(options, voted_ids) when is_list(options) do
    voted = MapSet.new(voted_ids)

    options
    |> Enum.with_index()
    |> Enum.flat_map(fn {o, idx} -> if MapSet.member?(voted, o.id), do: [idx], else: [] end)
  end
end
