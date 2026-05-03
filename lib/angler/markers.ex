defmodule Angler.Markers do
  @moduledoc """
  Per-timeline read-position markers. Mastodon supports `home` and
  `notifications`. Each `set/3` bumps `version` for optimistic concurrency
  on the client side; we don't currently reject conflicting writes.
  """

  import Ecto.Query, warn: false

  alias Angler.Markers.Marker
  alias Angler.Repo

  @spec get(integer(), [String.t()]) :: %{String.t() => Marker.t()}
  def get(profile_id, timelines) when is_integer(profile_id) and is_list(timelines) do
    timelines = Enum.filter(timelines, &(&1 in Marker.timelines()))

    if timelines == [] do
      %{}
    else
      Repo.all(
        from m in Marker,
          where: m.profile_id == ^profile_id and m.timeline in ^timelines
      )
      |> Map.new(fn m -> {m.timeline, m} end)
    end
  end

  @spec set(integer(), String.t(), integer()) ::
          {:ok, Marker.t()} | {:error, Ecto.Changeset.t()}
  def set(profile_id, timeline, last_read_id)
      when is_integer(profile_id) and is_binary(timeline) and is_integer(last_read_id) do
    result =
      %{
        profile_id: profile_id,
        timeline: timeline,
        last_read_id: last_read_id
      }
      |> Marker.changeset()
      |> Repo.insert(
        on_conflict: [
          set: [last_read_id: last_read_id, updated_at: DateTime.utc_now()],
          inc: [version: 1]
        ],
        conflict_target: [:profile_id, :timeline]
      )

    # The returned row reflects what we tried to insert, not the post-conflict
    # state. Reload so the caller sees the bumped `version`.
    case result do
      {:ok, _} ->
        {:ok, Repo.get_by!(Marker, profile_id: profile_id, timeline: timeline)}

      err ->
        err
    end
  end
end
