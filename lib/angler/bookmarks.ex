defmodule Angler.Bookmarks do
  @moduledoc "Bookmarks: per-user saved status references. No federation."

  import Ecto.Query, warn: false

  alias Angler.Bookmarks.Bookmark
  alias Angler.Repo

  @doc "Bookmark `status` for `profile`. Idempotent."
  @spec bookmark(integer(), integer()) :: {:ok, Bookmark.t()} | {:error, term()}
  def bookmark(profile_id, status_id)
      when is_integer(profile_id) and is_integer(status_id) do
    case Repo.get_by(Bookmark, profile_id: profile_id, status_id: status_id) do
      %Bookmark{} = existing ->
        {:ok, existing}

      nil ->
        %{profile_id: profile_id, status_id: status_id}
        |> Bookmark.changeset()
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:profile_id, :status_id])
        |> case do
          {:ok, %Bookmark{id: id}} when is_integer(id) -> {:ok, Repo.get!(Bookmark, id)}
          {:ok, _} -> {:ok, Repo.get_by!(Bookmark, profile_id: profile_id, status_id: status_id)}
          err -> err
        end
    end
  end

  @doc "Remove a bookmark. Idempotent."
  @spec unbookmark(integer(), integer()) :: :ok
  def unbookmark(profile_id, status_id) do
    Repo.delete_all(
      from b in Bookmark,
        where: b.profile_id == ^profile_id and b.status_id == ^status_id
    )

    :ok
  end

  @doc "Whether `profile_id` has bookmarked `status_id`."
  @spec bookmarked?(integer(), integer()) :: boolean()
  def bookmarked?(profile_id, status_id) do
    Repo.exists?(
      from b in Bookmark,
        where: b.profile_id == ^profile_id and b.status_id == ^status_id
    )
  end
end
