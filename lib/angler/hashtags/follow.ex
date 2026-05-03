defmodule Angler.Hashtags.Follow do
  @moduledoc "Per-user hashtag follow."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Hashtags.Hashtag
  alias Angler.Profiles.Profile

  schema "followed_tags" do
    belongs_to :profile, Profile, type: :integer
    belongs_to :hashtag, Hashtag
    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
  end

  def changeset(follow \\ %__MODULE__{}, attrs) do
    follow
    |> cast(attrs, [:profile_id, :hashtag_id])
    |> validate_required([:profile_id, :hashtag_id])
    |> unique_constraint([:profile_id, :hashtag_id])
  end
end
