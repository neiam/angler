defmodule Angler.Profiles.Mute do
  @moduledoc "An account-level mute. Local-only. `hide_notifications` defaults true."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Profiles.Profile

  schema "profile_mutes" do
    belongs_to :profile, Profile, type: :integer
    belongs_to :target, Profile, type: :integer
    field :hide_notifications, :boolean, default: true
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(mute \\ %__MODULE__{}, attrs) do
    mute
    |> cast(attrs, [:profile_id, :target_id, :hide_notifications])
    |> validate_required([:profile_id, :target_id])
    |> unique_constraint([:profile_id, :target_id])
  end
end
