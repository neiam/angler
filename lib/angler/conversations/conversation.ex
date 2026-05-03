defmodule Angler.Conversations.Conversation do
  @moduledoc """
  A direct-visibility thread between an owner and a fixed set of participants.

  One row per `(owner, sorted-participant-ids)` pair — we maintain a row for
  each participant of a given direct thread so unread/last-status state can
  diverge per recipient.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Profiles.Profile
  alias Angler.Statuses.Status

  @primary_key {:id, :integer, autogenerate: false}
  schema "conversations" do
    field :participant_ids, {:array, :integer}, default: []
    field :unread, :boolean, default: true

    belongs_to :owner, Profile, type: :integer
    belongs_to :last_status, Status, type: :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(conv \\ %__MODULE__{}, attrs) do
    conv
    |> maybe_assign_id()
    |> cast(attrs, [:owner_id, :participant_ids, :last_status_id, :unread])
    |> validate_required([:owner_id, :participant_ids])
    |> unique_constraint([:owner_id, :participant_ids])
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = c), do: %{c | id: Angler.Snowflake.next()}
  defp maybe_assign_id(c), do: c
end
