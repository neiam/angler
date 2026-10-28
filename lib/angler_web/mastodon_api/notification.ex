defmodule AnglerWeb.MastodonAPI.Notification do
  @moduledoc """
  Render an `Angler.Notifications.Notification` as a Mastodon `Notification`
  JSON object. See `plans/_types/notification.md`.

  A DM's notification (`direct`) carries upstream's `direct` pointer,
  `{conversation_id, message_id}`, so a client can open the conversation.
  Its type is `direct` for the Pixelfed app (`pe: true`) and `mention` for
  Mastodon clients, which is how Mastodon itself notifies DMs.
  """

  alias Angler.Notifications.Notification
  alias AnglerWeb.MastodonAPI.{Account, Status}

  @spec render(Notification.t(), integer() | nil, keyword()) :: map()
  def render(%Notification{} = n, viewer_id \\ nil, opts \\ []) do
    base = base(n, opts)

    case n.status do
      nil -> base
      status -> Map.put(base, "status", Status.render(status, viewer_id))
    end
  end

  @spec render_many([Notification.t()], integer() | nil, keyword()) :: [map()]
  def render_many(notifications, viewer_id \\ nil, opts \\ [])

  def render_many(notifications, viewer_id, opts) do
    statuses = Enum.flat_map(notifications, fn n -> if n.status, do: [n.status], else: [] end)

    overlays =
      if viewer_id && statuses != [] do
        Angler.Statuses.ViewerOverlay.batch(viewer_id, Enum.map(statuses, & &1.id))
      else
        %{}
      end

    Enum.map(notifications, fn n ->
      base = base(n, opts)

      case n.status do
        nil ->
          base

        status ->
          rendered = Status.render(status, nil)

          rendered =
            case Map.get(overlays, status.id) do
              nil -> rendered
              overlay -> Status.apply_viewer_overlay(rendered, overlay)
            end

          Map.put(base, "status", rendered)
      end
    end)
  end

  defp base(%Notification{} = n, opts) do
    %{
      "id" => Integer.to_string(n.id),
      "type" => type(n.type, opts),
      "created_at" => DateTime.to_iso8601(n.inserted_at),
      "account" => Account.render(n.account)
    }
    |> put_direct(n)
  end

  defp type("direct", opts), do: if(opts[:pe], do: "direct", else: "mention")
  defp type(type, _opts), do: type

  defp put_direct(map, %Notification{type: "direct", status_id: sid}) when is_integer(sid) do
    case Angler.Conversations.conversation_id_for(sid) do
      nil ->
        map

      cid ->
        Map.put(map, "direct", %{
          "conversation_id" => Integer.to_string(cid),
          "message_id" => Integer.to_string(sid)
        })
    end
  end

  defp put_direct(map, _), do: map
end
