defmodule Angler.Profiles.FeaturedTags do
  @moduledoc "Featured-tag CRUD scoped to a single profile."

  import Ecto.Query, warn: false

  alias Angler.Hashtags
  alias Angler.Hashtags.Hashtag
  alias Angler.Profiles.{FeaturedTag, Profile}
  alias Angler.Repo

  @spec list(integer(), pos_integer()) :: [Hashtag.t()]
  def list(profile_id, limit \\ 10) do
    Repo.all(
      from ft in FeaturedTag,
        join: h in Hashtag,
        on: h.id == ft.hashtag_id,
        where: ft.profile_id == ^profile_id,
        order_by: [desc: ft.id],
        limit: ^limit,
        select: h
    )
  end

  @spec feature(Profile.t(), String.t()) :: {:ok, Hashtag.t()}
  def feature(%Profile{id: pid}, name) do
    tag = Hashtags.ensure!(name)

    %{profile_id: pid, hashtag_id: tag.id}
    |> FeaturedTag.changeset()
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:profile_id, :hashtag_id])

    {:ok, tag}
  end

  @spec unfeature(Profile.t(), integer()) :: :ok
  def unfeature(%Profile{id: pid}, hashtag_id) do
    {_, _} =
      from(ft in FeaturedTag,
        where: ft.profile_id == ^pid and ft.hashtag_id == ^hashtag_id
      )
      |> Repo.delete_all()

    :ok
  end
end
