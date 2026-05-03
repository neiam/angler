defmodule Angler.Statuses.Scheduled do
  @moduledoc """
  A queued local status. The author has called `POST /statuses` with
  `scheduled_at` more than five minutes in the future; we serialize the
  request params and a separate Oban worker fires them when they come due.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Profiles.Profile

  @primary_key {:id, :integer, autogenerate: false}
  schema "scheduled_statuses" do
    field :params, :map
    field :media_ids, {:array, :integer}, default: []
    field :scheduled_at, :utc_datetime_usec
    field :fired_at, :utc_datetime_usec

    belongs_to :profile, Profile, type: :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(scheduled \\ %__MODULE__{}, attrs) do
    scheduled
    |> maybe_assign_id()
    |> cast(attrs, [:profile_id, :params, :media_ids, :scheduled_at, :fired_at])
    |> validate_required([:profile_id, :params, :scheduled_at])
    |> foreign_key_constraint(:profile_id)
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = s), do: %{s | id: Angler.Snowflake.next()}
  defp maybe_assign_id(s), do: s
end
