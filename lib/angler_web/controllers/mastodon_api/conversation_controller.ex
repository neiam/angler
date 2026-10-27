defmodule AnglerWeb.MastodonAPI.ConversationController do
  @moduledoc """
    * GET    /api/v1/conversations
    * POST   /api/v1/conversations/:id/read
    * DELETE /api/v1/conversations/:id
    * GET    /api/v1/timelines/direct
  """

  use AnglerWeb, :controller

  alias Angler.Conversations
  alias AnglerWeb.MastodonAPI.Conversation, as: ConversationJSON
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.Plugs.BearerAuth

  def index(conn, params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    cursor = Angler.Pagination.MastodonCursor.parse(params, 20, 40)
    rows = Conversations.list(profile.id, cursor: cursor)

    conn =
      case Angler.Pagination.MastodonCursor.link_header(
             rows,
             url_without_cursor(conn),
             :last_status_id
           ) do
        nil -> conn
        link -> put_resp_header(conn, "link", link)
      end

    json(conn, ConversationJSON.render_many(rows, profile.id))
  end

  defp url_without_cursor(conn) do
    qs =
      conn.query_params |> Map.drop(["max_id", "min_id", "since_id"]) |> Plug.Conn.Query.encode()

    base = AnglerWeb.Endpoint.url() <> conn.request_path
    if qs == "", do: base, else: base <> "?" <> qs
  end

  def read(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         {:ok, conv} <- Conversations.mark_read(profile.id, int_id) do
      conv = Angler.Repo.preload(conv, last_status: :profile)
      json(conn, ConversationJSON.render(conv, profile.id))
    else
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  def delete(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %_{} <- Conversations.get(profile.id, int_id) do
      :ok = Conversations.delete(profile.id, int_id)
      json(conn, %{})
    else
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  def direct_timeline(conn, _params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    statuses = Conversations.direct_timeline(profile.id)
    json(conn, StatusJSON.render_many(statuses, profile.id))
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}
  defp parse_id(_), do: :error
end
