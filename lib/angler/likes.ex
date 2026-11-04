defmodule Angler.Likes do
  @moduledoc "Likes (favourites)."

  import Ecto.Query, warn: false
  alias Angler.Likes.Like
  alias Angler.Repo

  @doc "Insert a like; idempotent on (profile, status)."
  @spec insert(map()) :: {:ok, Like.t()} | {:error, term()}
  def insert(attrs) when is_map(attrs) do
    case Like.changeset(attrs)
         |> Repo.insert(on_conflict: :nothing, conflict_target: [:profile_id, :status_id]) do
      {:ok, %Like{id: id}} when is_integer(id) -> {:ok, Repo.get!(Like, id)}
      {:ok, _} -> {:ok, get_existing!(attrs)}
      {:error, _} = err -> err
    end
  end

  defp get_existing!(attrs) do
    Repo.get_by!(Like,
      profile_id: attr(attrs, :profile_id),
      status_id: attr(attrs, :status_id)
    )
  end

  # Callers pass atom- or string-keyed attrs; the atom key wins.
  defp attr(attrs, key), do: attrs[key] || attrs[Atom.to_string(key)]

  @doc "Remove a like by `(profile_id, status_id)`. Returns count removed."
  @spec delete(integer(), integer()) :: integer()
  def delete(profile_id, status_id) do
    {n, _} =
      from(l in Like,
        where: l.profile_id == ^profile_id and l.status_id == ^status_id
      )
      |> Repo.delete_all()

    n
  end

  @doc "Find a like by remote_url (for inbound Undo)."
  @spec get_by_remote_url(String.t()) :: Like.t() | nil
  def get_by_remote_url(url) when is_binary(url) do
    Repo.get_by(Like, remote_url: url)
  end
end
