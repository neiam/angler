defmodule AnglerWeb.StreamingController do
  @moduledoc """
  Upgrades `GET /api/v1/streaming` (and the legacy single-stream URLs) into a
  WebSocket connection handled by `AnglerWeb.StreamingHandler`.

  Auth: `?access_token=...` query param OR a `Sec-WebSocket-Protocol` header
  whose first protocol is the bearer token (Mastodon's wss-friendly form).

  Stream selection: optional `?stream=user|public|public:local|direct` or
  `?stream=hashtag&tag=foo`. Plus the legacy `/streaming/<stream>` paths
  some clients still use.
  """

  use AnglerWeb, :controller

  alias Angler.OAuth
  alias Angler.Streaming

  def upgrade(conn, params) do
    case authenticate(conn) do
      {:ok, token} ->
        topics = initial_topics(token, conn, params)
        Enum.each(topics, &Streaming.subscribe/1)

        WebSockAdapter.upgrade(
          conn,
          AnglerWeb.StreamingHandler,
          %{token: token, topics: topics},
          timeout: 60_000
        )
        |> halt()

      :error ->
        conn |> send_resp(401, ~s({"error":"The access token is invalid"})) |> halt()
    end
  end

  defp authenticate(conn) do
    raw =
      case conn.query_params["access_token"] do
        v when is_binary(v) and v != "" ->
          v

        _ ->
          case Plug.Conn.get_req_header(conn, "sec-websocket-protocol") do
            [proto | _] -> proto |> String.split(",") |> hd() |> String.trim()
            _ -> nil
          end
      end

    case raw && OAuth.lookup_by_access(raw) do
      {:ok, token} -> {:ok, token}
      _ -> :error
    end
  end

  defp initial_topics(token, conn, params) do
    base =
      case params["stream"] do
        "user" -> ["user:#{token.profile_id}"]
        "public" -> ["public"]
        "public:local" -> ["public:local"]
        "direct" -> ["user:#{token.profile_id}"]
        "hashtag" -> if(is_binary(params["tag"]), do: ["hashtag:#{params["tag"]}"], else: [])
        _ -> []
      end

    case path_stream(conn) do
      nil -> base
      "user" -> ["user:#{token.profile_id}" | base] |> Enum.uniq()
      "public" -> ["public" | base] |> Enum.uniq()
      "public:local" -> ["public:local" | base] |> Enum.uniq()
      "direct" -> ["user:#{token.profile_id}" | base] |> Enum.uniq()
      _ -> base
    end
  end

  defp path_stream(conn) do
    case conn.path_info do
      ["api", "v1", "streaming", stream] -> stream
      _ -> nil
    end
  end
end
