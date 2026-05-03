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

  def index(conn, _params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    rows = Conversations.list(profile.id)
    json(conn, ConversationJSON.render_many(rows, profile.id))
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
