defmodule Angler.Conversations.Conversation do
  @moduledoc """
  A direct-message conversation: a fixed set of participants, local and
  remote, identified by `participants_hash` (sha256 of the sorted profile
  ids joined with `:`), so the same people always land in the same one.
  `type` is `"dm"` for two people and `"group"` for more.
  """

  use Ecto.Schema

  alias Angler.Conversations.Participant
  alias Angler.Statuses.Status

  schema "dm_conversations" do
    field :type, :string, default: "dm"
    field :participants_hash, :string
    field :name, :string
    field :created_by_profile_id, :integer
    field :last_message_at, :utc_datetime_usec

    belongs_to :last_message, Status, type: :integer
    has_many :participants, Participant

    timestamps(type: :utc_datetime_usec)
  end

  @spec hash([integer()]) :: String.t()
  def hash(profile_ids) do
    ids = profile_ids |> Enum.uniq() |> Enum.sort() |> Enum.map_join(":", &Integer.to_string/1)
    :crypto.hash(:sha256, ids) |> Base.encode16(case: :lower)
  end
end
