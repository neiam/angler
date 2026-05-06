defmodule Angler.Groups.Report do
  @moduledoc "Per-group report — distinct from instance-level reports."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Groups.Group
  alias Angler.Profiles.Profile

  @primary_key {:id, :integer, autogenerate: false}
  schema "group_reports" do
    field :object_type, :string
    field :object_id, :integer
    field :report_type, :string
    field :message, :string
    field :resolved_at, :utc_datetime_usec

    belongs_to :group, Group, type: :integer
    belongs_to :reporter, Profile, foreign_key: :reporter_profile_id, type: :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(r \\ %__MODULE__{}, attrs) do
    r
    |> maybe_assign_id()
    |> cast(attrs, [
      :group_id,
      :reporter_profile_id,
      :object_type,
      :object_id,
      :report_type,
      :message,
      :resolved_at
    ])
    |> validate_required([:group_id, :object_type, :object_id])
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = r), do: %{r | id: Angler.Snowflake.next()}
  defp maybe_assign_id(r), do: r
end
