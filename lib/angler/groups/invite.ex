defmodule Angler.Groups.Invite do
  @moduledoc "Pre-issued invitation to join a group; bypasses the join-request approval step."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Groups.Group
  alias Angler.Profiles.Profile

  @primary_key {:id, :integer, autogenerate: false}
  schema "group_invites" do
    field :accepted_at, :utc_datetime_usec
    field :declined_at, :utc_datetime_usec

    belongs_to :group, Group, type: :integer
    belongs_to :profile, Profile, type: :integer
    belongs_to :inviter, Profile, foreign_key: :inviter_profile_id, type: :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(inv \\ %__MODULE__{}, attrs) do
    inv
    |> maybe_assign_id()
    |> cast(attrs, [:group_id, :profile_id, :inviter_profile_id, :accepted_at, :declined_at])
    |> validate_required([:group_id, :profile_id])
    |> unique_constraint([:group_id, :profile_id])
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = i), do: %{i | id: Angler.Snowflake.next()}
  defp maybe_assign_id(i), do: i
end
