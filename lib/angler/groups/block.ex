defmodule Angler.Groups.Block do
  @moduledoc "Per-group blocklist entry — bans a profile from posting/joining."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Groups.Group
  alias Angler.Profiles.Profile

  @primary_key {:id, :integer, autogenerate: false}
  schema "group_blocks" do
    field :reason, :string

    belongs_to :group, Group, type: :integer
    belongs_to :profile, Profile, type: :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(b \\ %__MODULE__{}, attrs) do
    b
    |> maybe_assign_id()
    |> cast(attrs, [:group_id, :profile_id, :reason])
    |> validate_required([:group_id, :profile_id])
    |> unique_constraint([:group_id, :profile_id])
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = b), do: %{b | id: Angler.Snowflake.next()}
  defp maybe_assign_id(b), do: b
end
