defmodule Angler.Conversations.Message do
  @moduledoc "Which conversation a `:direct` status belongs to. The status is the message."

  use Ecto.Schema

  alias Angler.Conversations.Conversation
  alias Angler.Statuses.Status

  schema "dm_conversation_messages" do
    belongs_to :conversation, Conversation
    belongs_to :status, Status, type: :integer
  end
end
