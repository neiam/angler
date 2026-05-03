defmodule Angler.Relationships do
  @moduledoc """
  Compute relationship state between a viewer and one or more target profiles.

  See `plans/_types/relationship.md`. Block / mute / domain-block fields are
  always `false` until those tables ship — the seam is here so the renderer
  doesn't change shape later.
  """

  import Ecto.Query, warn: false

  alias Angler.Follows.{FollowRequest, Follower}
  alias Angler.Profiles.{Block, Mute}
  alias Angler.Repo

  @type t :: %{
          id: integer(),
          following: boolean(),
          followed_by: boolean(),
          requested: boolean(),
          requested_by: boolean(),
          showing_reblogs: boolean(),
          notifying: boolean(),
          blocking: boolean(),
          blocked_by: boolean(),
          muting: boolean(),
          muting_notifications: boolean(),
          domain_blocking: boolean(),
          endorsed: boolean(),
          note: String.t()
        }

  @doc """
  Compute relationship state for `viewer_id` against each of `target_ids`.

  Returns a map keyed by target id. Targets with no edges still get an entry
  (all-false defaults).
  """
  @spec batch(integer(), [integer()]) :: %{integer() => t()}
  def batch(viewer_id, target_ids) when is_integer(viewer_id) and is_list(target_ids) do
    target_ids = Enum.uniq(target_ids)

    if target_ids == [] do
      %{}
    else
      followings = follow_lookup(viewer_id, target_ids, :viewer_follows_target)
      followers = follow_lookup(viewer_id, target_ids, :target_follows_viewer)
      requested = request_lookup(viewer_id, target_ids, :viewer_requests_target)
      requested_by = request_lookup(viewer_id, target_ids, :target_requests_viewer)
      blocking = block_lookup(viewer_id, target_ids, :viewer_blocks_target)
      blocked_by = block_lookup(viewer_id, target_ids, :target_blocks_viewer)
      muting = mute_lookup(viewer_id, target_ids)

      Map.new(target_ids, fn tid ->
        following_row = Map.get(followings, tid)
        follower_row = Map.get(followers, tid)
        mute_row = Map.get(muting, tid)

        {tid,
         %{
           id: tid,
           following: not is_nil(following_row) and not is_nil(following_row.accepted_at),
           followed_by: not is_nil(follower_row) and not is_nil(follower_row.accepted_at),
           requested: MapSet.member?(requested, tid),
           requested_by: MapSet.member?(requested_by, tid),
           showing_reblogs: showing_reblogs(following_row),
           notifying: notifying(following_row),
           blocking: MapSet.member?(blocking, tid),
           blocked_by: MapSet.member?(blocked_by, tid),
           muting: not is_nil(mute_row),
           muting_notifications: mute_row && mute_row.hide_notifications,
           domain_blocking: false,
           endorsed: false,
           note: ""
         }}
      end)
    end
  end

  @doc "Single-target convenience that wraps `batch/2`."
  @spec get(integer(), integer()) :: t()
  def get(viewer_id, target_id) when is_integer(viewer_id) and is_integer(target_id) do
    batch(viewer_id, [target_id]) |> Map.fetch!(target_id)
  end

  ## Internals

  # When `:viewer_follows_target`, viewer is the `following_id` (follower) and
  # target is the `profile_id` (followee).
  defp follow_lookup(viewer_id, target_ids, :viewer_follows_target) do
    from(f in Follower,
      where: f.following_id == ^viewer_id and f.profile_id in ^target_ids,
      select: %{
        target_id: f.profile_id,
        accepted_at: f.accepted_at,
        show_reblogs: f.show_reblogs,
        notify: f.notify
      }
    )
    |> Repo.all()
    |> Map.new(fn r -> {r.target_id, r} end)
  end

  # `:target_follows_viewer` — viewer is the followee.
  defp follow_lookup(viewer_id, target_ids, :target_follows_viewer) do
    from(f in Follower,
      where: f.profile_id == ^viewer_id and f.following_id in ^target_ids,
      select: %{
        target_id: f.following_id,
        accepted_at: f.accepted_at
      }
    )
    |> Repo.all()
    |> Map.new(fn r -> {r.target_id, r} end)
  end

  defp request_lookup(viewer_id, target_ids, :viewer_requests_target) do
    from(r in FollowRequest,
      where: r.following_id == ^viewer_id and r.profile_id in ^target_ids,
      select: r.profile_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp request_lookup(viewer_id, target_ids, :target_requests_viewer) do
    from(r in FollowRequest,
      where: r.profile_id == ^viewer_id and r.following_id in ^target_ids,
      select: r.following_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp showing_reblogs(nil), do: true
  defp showing_reblogs(%{show_reblogs: v}), do: v

  defp notifying(nil), do: false
  defp notifying(%{notify: v}), do: v

  defp block_lookup(viewer_id, target_ids, :viewer_blocks_target) do
    from(b in Block,
      where: b.profile_id == ^viewer_id and b.target_id in ^target_ids,
      select: b.target_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp block_lookup(viewer_id, target_ids, :target_blocks_viewer) do
    from(b in Block,
      where: b.target_id == ^viewer_id and b.profile_id in ^target_ids,
      select: b.profile_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp mute_lookup(viewer_id, target_ids) do
    from(m in Mute,
      where: m.profile_id == ^viewer_id and m.target_id in ^target_ids,
      select: %{target_id: m.target_id, hide_notifications: m.hide_notifications}
    )
    |> Repo.all()
    |> Map.new(fn r -> {r.target_id, r} end)
  end
end
