defmodule Angler.Statuses.ViewerOverlay do
  @moduledoc """
  Per-viewer flags on a status: `favourited`, `reblogged`, `bookmarked`,
  `pinned`, `muted`. Computed in a single batched query so a timeline of N
  statuses costs three small DB lookups regardless of N.

  Used by `AnglerWeb.MastodonAPI.Status.render/2` when a viewer id is
  supplied. Pure read; no writes.
  """

  import Ecto.Query, warn: false

  alias Angler.Bookmarks.Bookmark
  alias Angler.Likes.Like
  alias Angler.Reblogs.Reblog
  alias Angler.Repo

  @type overlay :: %{
          favourited: boolean(),
          reblogged: boolean(),
          bookmarked: boolean(),
          pinned: boolean(),
          muted: boolean()
        }

  @doc """
  Returns a map of `status_id => overlay` for a viewer over the given ids.

  When `viewer_id` is `nil`, returns an empty map (callers should treat all
  flags as `false`).
  """
  @spec batch(integer() | nil, [integer()]) :: %{integer() => overlay()}
  def batch(nil, _), do: %{}
  def batch(_, []), do: %{}

  def batch(viewer_id, status_ids) when is_integer(viewer_id) and is_list(status_ids) do
    ids = Enum.uniq(status_ids)

    favs =
      from(l in Like,
        where: l.profile_id == ^viewer_id and l.status_id in ^ids,
        select: l.status_id
      )
      |> Repo.all()
      |> MapSet.new()

    reblogs =
      from(r in Reblog,
        where: r.profile_id == ^viewer_id and r.status_id in ^ids,
        select: r.status_id
      )
      |> Repo.all()
      |> MapSet.new()

    bookmarks =
      from(b in Bookmark,
        where: b.profile_id == ^viewer_id and b.status_id in ^ids,
        select: b.status_id
      )
      |> Repo.all()
      |> MapSet.new()

    Map.new(ids, fn id ->
      {id,
       %{
         favourited: MapSet.member?(favs, id),
         reblogged: MapSet.member?(reblogs, id),
         bookmarked: MapSet.member?(bookmarks, id),
         pinned: false,
         muted: false
       }}
    end)
  end

  @doc "Single-status convenience that wraps `batch/2`."
  @spec for_status(integer() | nil, integer()) :: overlay()
  def for_status(viewer_id, status_id) do
    case batch(viewer_id, [status_id]) do
      %{^status_id => o} -> o
      _ -> empty()
    end
  end

  @doc "All-false default overlay."
  @spec empty() :: overlay()
  def empty do
    %{favourited: false, reblogged: false, bookmarked: false, pinned: false, muted: false}
  end
end
