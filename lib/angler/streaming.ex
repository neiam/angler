defmodule Angler.Streaming do
  @moduledoc """
  Mastodon-shape WebSocket streaming bus.

  Mutating call sites broadcast over `Phoenix.PubSub` on well-known topics:

    * `"user:<profile_id>"` — notifications + the user's own statuses
    * `"public"` — public-visibility statuses (federation + local)
    * `"public:local"` — local-only public statuses
    * `"hashtag:<name>"` — public statuses tagged with `<name>`

  The WebSocket handler (`AnglerWeb.StreamingHandler`) subscribes to one or
  more of these topics on connect and converts each broadcast into a
  Mastodon-format frame:

      {"event": "<name>", "stream": ["<stream>"], "payload": "<json string>"}
  """

  alias Angler.Notifications.Notification
  alias Angler.Statuses.Status
  alias AnglerWeb.MastodonAPI.Notification, as: NotificationJSON
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON

  ## Broadcasters

  @doc "Notify a user of a new notification."
  @spec broadcast_notification(Notification.t()) :: :ok
  def broadcast_notification(%Notification{} = n) do
    n = Angler.Repo.preload(n, [:account, status: :profile])
    payload = n |> NotificationJSON.render(n.recipient_id) |> Jason.encode!()
    publish("user:#{n.recipient_id}", "notification", payload)
  end

  @doc """
  Broadcast a freshly-created status to all relevant streams.

  * `public` and `public:local` for `:public` visibility
  * `user:<follower_id>` for each accepted follower
  * `user:<author_id>` for the author themselves
  * `hashtag:<name>` for each tag on a public status
  """
  @spec broadcast_status_update(Status.t()) :: :ok
  def broadcast_status_update(%Status{} = status) do
    rendered = status |> StatusJSON.render(nil) |> Jason.encode!()

    publish("user:#{status.profile_id}", "update", rendered)

    if status.visibility == :public do
      publish("public", "update", rendered)
      if status.local, do: publish("public:local", "update", rendered)

      Enum.each(hashtags_for(status.id), fn name ->
        publish("hashtag:#{name}", "update", rendered)
      end)
    end

    fan_to_followers(status, "update", rendered)
    :ok
  end

  @doc "Broadcast a soft-deleted status id (Mastodon convention: payload is the id-string)."
  @spec broadcast_status_delete(integer(), Status.t()) :: :ok
  def broadcast_status_delete(status_id, %Status{} = status) do
    payload = Jason.encode!(Integer.to_string(status_id))

    publish("user:#{status.profile_id}", "delete", payload)

    if status.visibility == :public do
      publish("public", "delete", payload)
      if status.local, do: publish("public:local", "delete", payload)
    end

    fan_to_followers(status, "delete", payload)
    :ok
  end

  @doc "Broadcast an edit to all relevant streams (`status.update` event)."
  @spec broadcast_status_edit(Status.t()) :: :ok
  def broadcast_status_edit(%Status{} = status) do
    rendered = status |> StatusJSON.render(nil) |> Jason.encode!()

    publish("user:#{status.profile_id}", "status.update", rendered)

    if status.visibility == :public do
      publish("public", "status.update", rendered)
      if status.local, do: publish("public:local", "status.update", rendered)
    end

    fan_to_followers(status, "status.update", rendered)
    :ok
  end

  ## Subscribe / publish (used by the WS handler)

  @doc "Subscribe the current process to a stream topic."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic) when is_binary(topic) do
    Phoenix.PubSub.subscribe(Angler.PubSub, "streaming:" <> topic)
  end

  @doc "Unsubscribe the current process from a stream topic."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic) when is_binary(topic) do
    Phoenix.PubSub.unsubscribe(Angler.PubSub, "streaming:" <> topic)
  end

  defp publish(topic, event, payload) do
    Phoenix.PubSub.broadcast(
      Angler.PubSub,
      "streaming:" <> topic,
      {:streaming, topic, event, payload}
    )
  end

  ## Internals

  defp hashtags_for(status_id) do
    import Ecto.Query

    Angler.Repo.all(
      from sh in Angler.Statuses.StatusHashtag,
        join: h in Angler.Hashtags.Hashtag,
        on: h.id == sh.hashtag_id,
        where: sh.status_id == ^status_id,
        select: h.name
    )
  end

  defp fan_to_followers(%Status{visibility: :direct}, _event, _payload), do: :ok

  defp fan_to_followers(%Status{profile_id: author_id}, event, payload) do
    import Ecto.Query

    Angler.Repo.all(
      from f in Angler.Follows.Follower,
        where: f.profile_id == ^author_id and not is_nil(f.accepted_at),
        select: f.following_id
    )
    |> Enum.each(fn fid ->
      publish("user:#{fid}", event, payload)
    end)
  end
end
