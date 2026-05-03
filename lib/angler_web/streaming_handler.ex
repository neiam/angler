defmodule AnglerWeb.StreamingHandler do
  @moduledoc """
  Raw WebSocket handler for Mastodon-shape streaming.

  Mounted via `WebSockAdapter.upgrade/4` from `StreamingController`. On
  connect we authenticate the access token and subscribe to one or more
  Phoenix.PubSub topics; each message gets translated into a Mastodon
  frame:

      {"event": "<name>", "stream": ["<topic>"], "payload": "<json string>"}

  Clients can subscribe/unsubscribe at runtime by sending JSON frames:

      {"type": "subscribe", "stream": "public"}
      {"type": "unsubscribe", "stream": "hashtag", "tag": "photography"}
  """

  @behaviour WebSock

  alias Angler.Streaming

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "subscribe"} = msg} ->
        topic = topic_from(msg)

        if topic && topic not in state.topics do
          :ok = Streaming.subscribe(topic)
          {:ok, %{state | topics: [topic | state.topics]}}
        else
          {:ok, state}
        end

      {:ok, %{"type" => "unsubscribe"} = msg} ->
        topic = topic_from(msg)

        if topic do
          # Phoenix.PubSub doesn't take per-topic unsubscribe, but the handler
          # filtering by `state.topics` below prevents forwarding.
          {:ok, %{state | topics: List.delete(state.topics, topic)}}
        else
          {:ok, state}
        end

      _ ->
        {:ok, state}
    end
  end

  def handle_in(_other, state), do: {:ok, state}

  @impl true
  def handle_info({:streaming, topic, event, payload_json}, state) do
    if topic in state.topics do
      frame =
        Jason.encode!(%{
          "event" => event,
          "stream" => [stream_name(topic)],
          "payload" => payload_json
        })

      {:push, {:text, frame}, state}
    else
      {:ok, state}
    end
  end

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  ## Helpers

  defp topic_from(%{"stream" => "user"}), do: "user"
  defp topic_from(%{"stream" => "public"}), do: "public"
  defp topic_from(%{"stream" => "public:local"}), do: "public:local"
  defp topic_from(%{"stream" => "direct"}), do: "direct"

  defp topic_from(%{"stream" => "hashtag", "tag" => tag}) when is_binary(tag),
    do: "hashtag:#{tag}"

  defp topic_from(_), do: nil

  # The "stream" value in Mastodon's frame envelope is the *original* request
  # name without the colon-suffix for hashtags.
  defp stream_name("hashtag:" <> _), do: "hashtag"
  defp stream_name(name), do: name
end
