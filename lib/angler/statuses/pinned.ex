defmodule Angler.Statuses.Pinned do
  @moduledoc """
  Pinned-status row. Up to `Angler.Statuses.Pinning.max/0` per profile.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Profiles.Profile
  alias Angler.Statuses.Status

  schema "pinned_statuses" do
    field :position, :integer, default: 0
    belongs_to :profile, Profile, type: :integer
    belongs_to :status, Status, type: :integer
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(pin \\ %__MODULE__{}, attrs) do
    pin
    |> cast(attrs, [:profile_id, :status_id, :position])
    |> validate_required([:profile_id, :status_id])
    |> unique_constraint([:profile_id, :status_id])
  end
end
