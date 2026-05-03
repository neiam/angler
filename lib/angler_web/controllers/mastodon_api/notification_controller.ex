defmodule AnglerWeb.MastodonAPI.NotificationController do
  @moduledoc """
  GET/POST /api/v1/notifications endpoints.

  Mirrors Mastodon's notification API:

    * GET  /api/v1/notifications              — paginated list
    * GET  /api/v1/notifications/:id          — single notification
    * POST /api/v1/notifications/clear        — dismiss all
    * POST /api/v1/notifications/:id/dismiss  — dismiss one
  """

  use AnglerWeb, :controller

  alias Angler.Notifications
  alias Angler.Pagination.MastodonCursor
  alias AnglerWeb.MastodonAPI.Notification, as: NotificationJSON
  alias AnglerWeb.Plugs.BearerAuth

  def index(conn, params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    params = normalize_filters(params)

    {rows, cursor_rows} = Notifications.list(profile.id, params)

    conn =
      case MastodonCursor.link_header(cursor_rows, current_url_without_cursor(conn), :id) do
        nil -> conn
        v -> put_resp_header(conn, "link", v)
      end

    json(conn, NotificationJSON.render_many(rows, profile.id))
  end

  def show(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %_{} = notification <- Notifications.get(profile.id, int_id) do
      json(conn, NotificationJSON.render(notification, profile.id))
    else
      _ -> send_error(conn, 404, "Record not found")
    end
  end

  def clear(conn, _params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    :ok = Notifications.clear(profile.id)
    json(conn, %{})
  end

  def dismiss(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    case parse_id(id) do
      {:ok, int_id} ->
        :ok = Notifications.dismiss(profile.id, int_id)
        json(conn, %{})

      _ ->
        send_error(conn, 404, "Record not found")
    end
  end

  ## Internals

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}
  defp parse_id(_), do: :error

  # Mastodon passes types as `types[]=mention&types[]=favourite`; Plug
  # surfaces these as `"types" => [...]` already. We also tolerate the
  # singular `"type"` form for convenience.
  defp normalize_filters(params) do
    params
    |> Map.update("types", List.wrap(params["type"] || params["types"]), fn v -> List.wrap(v) end)
    |> Map.update("exclude_types", List.wrap(params["exclude_types"]), fn v -> List.wrap(v) end)
  end

  defp current_url_without_cursor(conn) do
    qs =
      conn.query_params
      |> Map.drop(["max_id", "min_id", "since_id"])
      |> Plug.Conn.Query.encode()

    base = current_url(conn) |> URI.parse() |> Map.put(:query, nil) |> URI.to_string()
    if qs == "", do: base, else: base <> "?" <> qs
  end

  defp send_error(conn, status, msg) do
    conn |> put_status(status) |> json(%{"error" => msg})
  end
end
