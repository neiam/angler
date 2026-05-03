defmodule Angler.Federation.Activity do
  @moduledoc """
  Append-only log of inbound + outbound AP activities. Acts as the dedup key
  for inbound idempotency and the audit trail for outbound delivery.

  See `plans/federation/models/federation_activity.md`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "federation_activities" do
    field :direction, Ecto.Enum, values: [:inbound, :outbound]
    field :activity_id, :string
    field :activity_type, :string
    field :actor_url, :string
    field :object_type, :string
    field :object_id, :string
    field :target_inbox, :string
    field :payload, :map
    field :raw_body, :binary

    field :status, Ecto.Enum,
      values: [:pending, :delivered, :rejected, :error],
      default: :pending

    field :error, :string
    field :delivered_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(activity \\ %__MODULE__{}, attrs) do
    activity
    |> cast(attrs, [
      :direction,
      :activity_id,
      :activity_type,
      :actor_url,
      :object_type,
      :object_id,
      :target_inbox,
      :payload,
      :raw_body,
      :status,
      :error,
      :delivered_at
    ])
    |> validate_required([:direction])
    |> unique_constraint([:direction, :activity_id, :actor_url],
      name: :federation_activities_dedup_idx
    )
  end
end
