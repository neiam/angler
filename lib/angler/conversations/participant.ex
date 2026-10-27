defmodule Angler.Conversations.Participant do
  @moduledoc """
  One member's view of a conversation: `state` (`"active"`, `"request"` —
  not yet accepted — or `"left"`, groups only), read pointer, unread count,
  and the muted / hidden marks. Remote members have rows too; only local
  rows' state is maintained.
  """

  use Ecto.Schema

  alias Angler.Conversations.Conversation
  alias Angler.Profiles.Profile

  @states ~w(active request left)

  schema "dm_conversation_participants" do
    field :state, :string, default: "active"
    field :last_read_message_id, :integer
    field :unread_count, :integer, default: 0
    field :last_activity_at, :utc_datetime_usec
    field :muted_at, :utc_datetime_usec
    field :hidden_at, :utc_datetime_usec

    belongs_to :conversation, Conversation
    belongs_to :profile, Profile, type: :integer

    timestamps(type: :utc_datetime_usec)
  end

  def states, do: @states
end
