defmodule Angler.Reblogs do
  @moduledoc "Reblogs (Mastodon `Announce`)."

  import Ecto.Query, warn: false
  alias Angler.Reblogs.Reblog
  alias Angler.Repo

  @doc "Insert a reblog; idempotent on (profile, status)."
  @spec insert(map()) :: {:ok, Reblog.t()} | {:error, term()}
  def insert(attrs) when is_map(attrs) do
    case Reblog.changeset(attrs)
         |> Repo.insert(on_conflict: :nothing, conflict_target: [:profile_id, :status_id]) do
      {:ok, %Reblog{id: id}} when is_integer(id) -> {:ok, Repo.get!(Reblog, id)}
      {:ok, _} -> {:ok, get_existing!(attrs)}
      {:error, _} = err -> err
    end
  end

  defp get_existing!(attrs) do
    Repo.get_by!(Reblog,
      profile_id: attrs[:profile_id] || attrs["profile_id"],
      status_id: attrs[:status_id] || attrs["status_id"]
    )
  end

  @doc "The boost whose wrapper status has this id, with booster and post loaded."
  @spec get_by_wrapper_id(integer()) :: Reblog.t() | nil
  def get_by_wrapper_id(id) when is_integer(id) do
    from(r in Reblog, where: r.reblog_status_id == ^id, preload: [:profile, :status])
    |> Repo.one()
    |> case do
      %Reblog{status: %{deleted_at: nil}} = r -> r
      _ -> nil
    end
  end

  @doc "Remove a reblog by `(profile_id, status_id)`. Returns count removed."
  @spec delete(integer(), integer()) :: integer()
  def delete(profile_id, status_id) do
    {n, _} =
      from(r in Reblog,
        where: r.profile_id == ^profile_id and r.status_id == ^status_id
      )
      |> Repo.delete_all()

    n
  end

  @doc "Find a reblog by remote_url (for inbound Undo)."
  @spec get_by_remote_url(String.t()) :: Reblog.t() | nil
  def get_by_remote_url(url) when is_binary(url) do
    Repo.get_by(Reblog, remote_url: url)
  end
end
