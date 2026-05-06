defmodule Angler.Groups.Member do
  @moduledoc "Membership edge between a profile and a group."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Groups.Group
  alias Angler.Profiles.Profile

  @roles ~w(owner admin member)

  @primary_key {:id, :integer, autogenerate: false}
  schema "group_members" do
    field :role, :string, default: "member"
    # nil = pending join request; non-nil = accepted member
    field :accepted_at, :utc_datetime_usec

    belongs_to :group, Group, type: :integer
    belongs_to :profile, Profile, type: :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(m \\ %__MODULE__{}, attrs) do
    m
    |> maybe_assign_id()
    |> cast(attrs, [:group_id, :profile_id, :role, :accepted_at])
    |> validate_required([:group_id, :profile_id])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:group_id, :profile_id])
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = m), do: %{m | id: Angler.Snowflake.next()}
  defp maybe_assign_id(m), do: m

  def roles, do: @roles
end
