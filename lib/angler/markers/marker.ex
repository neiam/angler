defmodule Angler.Markers.Marker do
  @moduledoc "Per-(profile, timeline) read-position marker."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Profiles.Profile

  @timelines ~w(home notifications)

  schema "timeline_markers" do
    field :timeline, :string
    field :last_read_id, :integer
    field :version, :integer, default: 1
    belongs_to :profile, Profile, type: :integer
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(marker \\ %__MODULE__{}, attrs) do
    marker
    |> cast(attrs, [:profile_id, :timeline, :last_read_id, :version])
    |> validate_required([:profile_id, :timeline, :last_read_id])
    |> validate_inclusion(:timeline, @timelines)
    |> unique_constraint([:profile_id, :timeline])
  end

  def timelines, do: @timelines
end
