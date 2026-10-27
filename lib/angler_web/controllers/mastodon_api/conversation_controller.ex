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

    rows =
      profile.id
      |> Conversations.list_mastodon(cursor)
      |> Enum.sort_by(& &1.conversation.last_message_id, :desc)

    # Paged on the last message id, like upstream; rows are participant rows.
    keyed = Enum.map(rows, &%{last_status_id: &1.conversation.last_message_id})

    conn =
      case Angler.Pagination.MastodonCursor.link_header(
             keyed,
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
         %{} = row <- Conversations.get_mastodon(profile.id, int_id) do
      row = Conversations.mark_read(row)

      json(
        conn,
        ConversationJSON.render(Conversations.get_mastodon(profile.id, row.id), profile.id)
      )
    else
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  # Mastodon "remove conversation" hides it for the viewer, as upstream.
  def delete(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %{} = row <- Conversations.get_mastodon(profile.id, int_id) do
      Conversations.hide(row)
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
