defmodule Angler.Statuses.Pinning do
  @moduledoc """
  Pinned-status lifecycle. A profile can pin up to `max/0` of their *own*
  public/unlisted statuses; private/direct posts cannot be pinned.
  """

  import Ecto.Query, warn: false

  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses.{Pinned, Status}

  @max_pinned 5

  def max, do: @max_pinned

  @spec pin(Profile.t(), Status.t()) ::
          {:ok, Pinned.t()} | {:error, :forbidden | :unpinnable | :limit_reached}
  def pin(%Profile{id: pid}, %Status{profile_id: spid}) when pid != spid, do: {:error, :forbidden}

  def pin(%Profile{}, %Status{visibility: v}) when v not in [:public, :unlisted],
    do: {:error, :unpinnable}

  def pin(%Profile{id: profile_id}, %Status{id: status_id}) do
    Repo.transaction(fn ->
      count =
        Repo.aggregate(from(p in Pinned, where: p.profile_id == ^profile_id), :count)

      cond do
        Repo.exists?(
          from p in Pinned,
            where: p.profile_id == ^profile_id and p.status_id == ^status_id
        ) ->
          Repo.get_by!(Pinned, profile_id: profile_id, status_id: status_id)

        count >= @max_pinned ->
          Repo.rollback(:limit_reached)

        true ->
          {:ok, row} =
            %{profile_id: profile_id, status_id: status_id, position: count}
            |> Pinned.changeset()
            |> Repo.insert()

          row
      end
    end)
    |> case do
      {:ok, pin} -> {:ok, pin}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec unpin(Profile.t(), Status.t()) :: :ok
  def unpin(%Profile{id: profile_id}, %Status{id: status_id}) do
    {_, _} =
      from(p in Pinned, where: p.profile_id == ^profile_id and p.status_id == ^status_id)
      |> Repo.delete_all()

    :ok
  end

  @spec pinned?(integer(), integer()) :: boolean()
  def pinned?(profile_id, status_id) do
    Repo.exists?(
      from p in Pinned,
        where: p.profile_id == ^profile_id and p.status_id == ^status_id
    )
  end

  @spec list(integer()) :: [Status.t()]
  def list(profile_id) do
    Repo.all(
      from p in Pinned,
        join: s in Status,
        on: s.id == p.status_id and is_nil(s.deleted_at),
        where: p.profile_id == ^profile_id,
        order_by: [asc: p.position, desc: p.id],
        limit: ^@max_pinned,
        select: s
    )
    |> Repo.preload([
      :profile,
      mentions: :profile,
      status_hashtags: :hashtag,
      media_attachments: []
    ])
  end
end
