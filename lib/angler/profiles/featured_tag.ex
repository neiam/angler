defmodule Angler.Profiles.FeaturedTag do
  @moduledoc "A hashtag the profile has pinned to their public bio."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Hashtags.Hashtag
  alias Angler.Profiles.Profile

  schema "featured_tags" do
    belongs_to :profile, Profile, type: :integer
    belongs_to :hashtag, Hashtag
    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
  end

  def changeset(ft \\ %__MODULE__{}, attrs) do
    ft
    |> cast(attrs, [:profile_id, :hashtag_id])
    |> validate_required([:profile_id, :hashtag_id])
    |> unique_constraint([:profile_id, :hashtag_id])
  end
end
