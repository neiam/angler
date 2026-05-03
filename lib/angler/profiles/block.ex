defmodule Angler.Profiles.Block do
  @moduledoc "An account-level block. Local-only."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Profiles.Profile

  schema "profile_blocks" do
    belongs_to :profile, Profile, type: :integer
    belongs_to :target, Profile, type: :integer
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(block \\ %__MODULE__{}, attrs) do
    block
    |> cast(attrs, [:profile_id, :target_id])
    |> validate_required([:profile_id, :target_id])
    |> unique_constraint([:profile_id, :target_id])
  end
end
