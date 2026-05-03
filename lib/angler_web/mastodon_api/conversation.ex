defmodule AnglerWeb.MastodonAPI.Conversation do
  @moduledoc """
  Mastodon `Conversation` JSON shape:

      { "id": "...",
        "unread": true,
        "accounts": [Account, ...],
        "last_status": Status | null }
  """

  alias Angler.Conversations.Conversation
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias AnglerWeb.MastodonAPI.{Account, Status}
  import Ecto.Query, only: [from: 2]

  @spec render(Conversation.t(), integer() | nil) :: map()
  def render(%Conversation{} = c, viewer_id \\ nil) do
    accounts =
      case c.participant_ids do
        [] -> []
        ids -> Repo.all(from p in Profile, where: p.id in ^ids)
      end

    %{
      "id" => Integer.to_string(c.id),
      "unread" => c.unread,
      "accounts" => Enum.map(accounts, &Account.render/1),
      "last_status" =>
        case c.last_status do
          %Ecto.Association.NotLoaded{} -> nil
          nil -> nil
          status -> Status.render(status, viewer_id)
        end
    }
  end

  def render_many(rows, viewer_id \\ nil), do: Enum.map(rows, &render(&1, viewer_id))
end
