defmodule AnglerWeb.MastodonAPI.Notification do
  @moduledoc """
  Render an `Angler.Notifications.Notification` as a Mastodon `Notification`
  JSON object. See `plans/_types/notification.md`.
  """

  alias Angler.Notifications.Notification
  alias AnglerWeb.MastodonAPI.{Account, Status}

  @spec render(Notification.t(), integer() | nil) :: map()
  def render(%Notification{} = n, viewer_id \\ nil) do
    base = %{
      "id" => Integer.to_string(n.id),
      "type" => n.type,
      "created_at" => DateTime.to_iso8601(n.inserted_at),
      "account" => Account.render(n.account)
    }

    case n.status do
      nil -> base
      status -> Map.put(base, "status", Status.render(status, viewer_id))
    end
  end

  @spec render_many([Notification.t()], integer() | nil) :: [map()]
  def render_many(notifications, viewer_id \\ nil)

  def render_many(notifications, viewer_id) do
    statuses = Enum.flat_map(notifications, fn n -> if n.status, do: [n.status], else: [] end)

    overlays =
      if viewer_id && statuses != [] do
        Angler.Statuses.ViewerOverlay.batch(viewer_id, Enum.map(statuses, & &1.id))
      else
        %{}
      end

    Enum.map(notifications, fn n ->
      base = %{
        "id" => Integer.to_string(n.id),
        "type" => n.type,
        "created_at" => DateTime.to_iso8601(n.inserted_at),
        "account" => Account.render(n.account)
      }

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
end
