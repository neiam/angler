defmodule Angler.Announcements do
  @moduledoc """
  Operator-written announcements + per-user dismissals.

  No public CRUD endpoint yet — operators populate via release task / iex.
  """

  import Ecto.Query, warn: false

  alias Angler.Announcements.{Announcement, Dismissal}
  alias Angler.Repo

  @spec list_active(integer()) :: [Announcement.t()]
  def list_active(viewer_id) do
    now = DateTime.utc_now()

    dismissed_ids =
      Repo.all(
        from d in Dismissal,
          where: d.profile_id == ^viewer_id,
          select: d.announcement_id
      )

    Repo.all(
      from a in Announcement,
        where:
          a.published == true and
            a.id not in ^dismissed_ids and
            (is_nil(a.starts_at) or a.starts_at <= ^now) and
            (is_nil(a.ends_at) or a.ends_at >= ^now),
        order_by: [desc: a.id]
    )
  end

  @spec dismiss(integer(), integer()) :: :ok
  def dismiss(profile_id, announcement_id) do
    %{profile_id: profile_id, announcement_id: announcement_id}
    |> Dismissal.changeset()
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:announcement_id, :profile_id])

    :ok
  end

  @spec create(map()) :: {:ok, Announcement.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    %Announcement{} |> Announcement.changeset(attrs) |> Repo.insert()
  end
end
