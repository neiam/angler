defmodule Angler.Stories.View do
  @moduledoc "One row per `(story, viewer)` who has seen the story."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Profiles.Profile
  alias Angler.Stories.Story

  schema "story_views" do
    belongs_to :story, Story, type: :integer
    belongs_to :profile, Profile, type: :integer
    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
  end

  def changeset(v \\ %__MODULE__{}, attrs) do
    v
    |> cast(attrs, [:story_id, :profile_id])
    |> validate_required([:story_id, :profile_id])
    |> unique_constraint([:story_id, :profile_id])
  end
end
