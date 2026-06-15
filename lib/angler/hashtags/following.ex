defmodule Angler.Hashtags.Following do
  @moduledoc "Per-user hashtag follow lifecycle."

  import Ecto.Query, warn: false

  alias Angler.Hashtags
  alias Angler.Hashtags.{Follow, Hashtag}
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Timelines.Workers.HashtagUnfollowPrune

  @spec follow(Profile.t(), String.t()) :: {:ok, Hashtag.t()}
  def follow(%Profile{id: profile_id}, name) when is_binary(name) do
    tag = Hashtags.ensure!(name)

    %{profile_id: profile_id, hashtag_id: tag.id}
    |> Follow.changeset()
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:profile_id, :hashtag_id])

    {:ok, tag}
  end

  @spec unfollow(Profile.t(), String.t()) :: :ok
  def unfollow(%Profile{id: profile_id}, name) when is_binary(name) do
    name = String.trim_leading(name, "#") |> String.downcase()

    case Hashtags.get_by_name(name) do
      nil ->
        :ok

      %Hashtag{id: hashtag_id} ->
        {deleted, _} =
          from(f in Follow,
            where: f.profile_id == ^profile_id and f.hashtag_id == ^hashtag_id
          )
          |> Repo.delete_all()

        # Strip posts already fanned in solely because of this follow. Runs
        # after the row is gone so the worker's "still-followed tag" check is
        # correct.
        if deleted > 0, do: HashtagUnfollowPrune.enqueue(profile_id, hashtag_id)

        :ok
    end
  end

  @spec following?(integer(), integer()) :: boolean()
  def following?(profile_id, hashtag_id) do
    Repo.exists?(
      from f in Follow,
        where: f.profile_id == ^profile_id and f.hashtag_id == ^hashtag_id
    )
  end

  @spec count(integer()) :: non_neg_integer()
  def count(profile_id) do
    Repo.aggregate(from(f in Follow, where: f.profile_id == ^profile_id), :count)
  end

  @spec list(integer(), pos_integer()) :: [Hashtag.t()]
  def list(profile_id, limit \\ 100) do
    Repo.all(
      from f in Follow,
        join: h in Hashtag,
        on: h.id == f.hashtag_id,
        where: f.profile_id == ^profile_id,
        order_by: [desc: f.id],
        limit: ^limit,
        select: h
    )
  end
end
