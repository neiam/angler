defmodule AnglerWeb.MastodonAPI.AnnouncementController do
  @moduledoc """
    * GET  /api/v1/announcements           — published, undismissed-by-viewer
    * POST /api/v1/announcements/:id/dismiss
  """

  use AnglerWeb, :controller

  alias Angler.Announcements
  alias Angler.Announcements.Announcement
  alias AnglerWeb.Plugs.BearerAuth

  def index(conn, _params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    json(conn, Enum.map(Announcements.list_active(profile.id), &render_one/1))
  end

  def dismiss(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    case parse_id(id) do
      {:ok, n} ->
        :ok = Announcements.dismiss(profile.id, n)
        json(conn, %{})

      _ ->
        conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  defp render_one(%Announcement{} = a) do
    %{
      "id" => Integer.to_string(a.id),
      "content" => a.text,
      "starts_at" => format_ts(a.starts_at),
      "ends_at" => format_ts(a.ends_at),
      "all_day" => a.all_day,
      "published_at" => format_ts(a.published_at || a.inserted_at),
      "updated_at" => format_ts(a.updated_at),
      "read" => false,
      "mentions" => [],
      "statuses" => [],
      "tags" => [],
      "emojis" => [],
      "reactions" => []
    }
  end

  defp format_ts(nil), do: nil
  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error
end
