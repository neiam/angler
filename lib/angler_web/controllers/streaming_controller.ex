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

  ## GET /api/v2/streaming/config
  ##
  ## Pixelfed historically returned a Pusher config block here. We don't
  ## use Pusher; clients should fall back to the `urls.streaming_api` field
  ## in `GET /api/v2/instance` when this is empty. Empty object preserves
  ## that fallback path without 404'ing.
  def config(conn, _params), do: json(conn, %{})

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
    base = stream_topics(params["stream"], token.profile_id, params["tag"])

    # A stream named in the path (no hashtags there) comes first.
    case path_stream(conn) do
      stream when stream in ["user", "public", "public:local", "direct"] ->
        Enum.uniq(stream_topics(stream, token.profile_id, nil) ++ base)

      _ ->
        base
    end
  end

  defp stream_topics(stream, profile_id, _tag) when stream in ["user", "direct"],
    do: ["user:#{profile_id}"]

  defp stream_topics("public", _profile_id, _tag), do: ["public"]
  defp stream_topics("public:local", _profile_id, _tag), do: ["public:local"]
  defp stream_topics("hashtag", _profile_id, tag) when is_binary(tag), do: ["hashtag:#{tag}"]
  defp stream_topics(_stream, _profile_id, _tag), do: []

  defp path_stream(conn) do
    case conn.path_info do
      ["api", "v1", "streaming", stream] -> stream
      _ -> nil
    end
  end
end
