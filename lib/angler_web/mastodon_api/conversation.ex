defmodule AnglerWeb.MastodonAPI.Conversation do
  @moduledoc """
  Mastodon `Conversation` JSON from the viewer's participant row:

      { "id": "<participant row id>",
        "unread": true,
        "accounts": [Account, ...],   # everyone but the viewer
        "last_status": Status | null }
  """

  alias Angler.Conversations.Participant
  alias AnglerWeb.MastodonAPI.{Account, Status}

  @spec render(Participant.t(), integer() | nil) :: map()
  def render(%Participant{conversation: conversation} = row, viewer_id \\ nil) do
    %{
      "id" => Integer.to_string(row.id),
      "unread" => row.unread_count > 0,
      "accounts" =>
        conversation.participants
        |> Enum.reject(&(&1.profile_id == row.profile_id))
        |> Enum.map(&Account.render(&1.profile)),
      "last_status" =>
        case conversation.last_message do
          nil -> nil
          status -> Status.render(status, viewer_id)
        end
    }
  end

  def render_many(rows, viewer_id \\ nil), do: Enum.map(rows, &render(&1, viewer_id))
end
