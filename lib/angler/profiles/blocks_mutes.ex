defmodule Angler.Profiles.BlocksMutes do
  @moduledoc """
  Block + mute lifecycle. Block also tears down any follow edges in either
  direction (blocked accounts can't follow you, and you stop following them).
  """

  import Ecto.Query, warn: false

  alias Angler.Follows
  alias Angler.Profiles.{Block, Mute, Profile}
  alias Angler.Repo

  ## Block

  @spec block(Profile.t(), Profile.t()) :: {:ok, Block.t()} | {:error, atom()}
  def block(%Profile{id: aid}, %Profile{id: bid}) when aid == bid, do: {:error, :self_block}

  def block(%Profile{} = actor, %Profile{} = target) do
    Repo.transaction(fn ->
      {:ok, row} =
        %{profile_id: actor.id, target_id: target.id}
        |> Block.changeset()
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:profile_id, :target_id])

      block = row.id || Repo.get_by!(Block, profile_id: actor.id, target_id: target.id)

      Follows.unfollow(actor, target)
      Follows.unfollow(target, actor)

      block
    end)
    |> case do
      {:ok, %Block{} = b} -> {:ok, b}
      {:ok, b_id} when is_integer(b_id) -> {:ok, Repo.get!(Block, b_id)}
      err -> err
    end
  end

  @spec unblock(Profile.t(), Profile.t()) :: :ok
  def unblock(%Profile{} = actor, %Profile{} = target) do
    Repo.delete_all(
      from b in Block, where: b.profile_id == ^actor.id and b.target_id == ^target.id
    )

    :ok
  end

  @spec blocked?(integer(), integer()) :: boolean()
  def blocked?(actor_id, target_id) do
    Repo.exists?(from b in Block, where: b.profile_id == ^actor_id and b.target_id == ^target_id)
  end

  @spec list_blocks(integer(), pos_integer()) :: [Profile.t()]
  def list_blocks(actor_id, limit \\ 40) do
    Repo.all(
      from b in Block,
        join: p in Profile,
        on: p.id == b.target_id,
        where: b.profile_id == ^actor_id,
        order_by: [desc: b.id],
        limit: ^limit,
        select: p
    )
  end

  @doc "Block ids the actor has blocked OR been blocked by — used to filter feeds."
  @spec block_ids_for(integer()) :: [integer()]
  def block_ids_for(actor_id) do
    Repo.all(
      from b in Block,
        where: b.profile_id == ^actor_id or b.target_id == ^actor_id,
        select:
          fragment(
            "CASE WHEN ? = ? THEN ? ELSE ? END",
            b.profile_id,
            ^actor_id,
            b.target_id,
            b.profile_id
          )
    )
    |> Enum.uniq()
  end

  ## Mute

  @spec mute(Profile.t(), Profile.t(), keyword()) :: {:ok, Mute.t()} | {:error, atom()}
  def mute(actor, target, opts \\ [])
  def mute(%Profile{id: aid}, %Profile{id: bid}, _) when aid == bid, do: {:error, :self_mute}

  def mute(%Profile{} = actor, %Profile{} = target, opts) do
    hide_notifications = Keyword.get(opts, :notifications, true)

    %{profile_id: actor.id, target_id: target.id, hide_notifications: hide_notifications}
    |> Mute.changeset()
    |> Repo.insert(
      on_conflict: {:replace, [:hide_notifications, :updated_at]},
      conflict_target: [:profile_id, :target_id]
    )
  end

  @spec unmute(Profile.t(), Profile.t()) :: :ok
  def unmute(%Profile{} = actor, %Profile{} = target) do
    Repo.delete_all(
      from m in Mute, where: m.profile_id == ^actor.id and m.target_id == ^target.id
    )

    :ok
  end

  @spec list_mutes(integer(), pos_integer()) :: [Profile.t()]
  def list_mutes(actor_id, limit \\ 40) do
    Repo.all(
      from m in Mute,
        join: p in Profile,
        on: p.id == m.target_id,
        where: m.profile_id == ^actor_id,
        order_by: [desc: m.id],
        limit: ^limit,
        select: p
    )
  end

  @spec mute_ids_for(integer()) :: [integer()]
  def mute_ids_for(actor_id) do
    Repo.all(from m in Mute, where: m.profile_id == ^actor_id, select: m.target_id)
  end
end
