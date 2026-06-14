defmodule AnglerWeb.TagLive do
  @moduledoc """
  Hashtag timeline at `/tags/:name` — public/unlisted posts tagged with
  `:name`, seeded from `Timelines.hashtag/3` and kept current by subscribing to
  the `"hashtag:<name>"` streaming topic. This is the destination for hashtag
  results in `AnglerWeb.SearchLive` and the navbar type-ahead.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.PublicComponents

  alias Angler.Pagination.MastodonCursor
  alias Angler.Streaming
  alias Angler.Timelines
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON

  @feed_limit 30

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    name = name |> String.downcase() |> String.trim_leading("#")
    topic = "hashtag:#{name}"

    viewer_id = socket.assigns.current_profile && socket.assigns.current_profile.id

    {posts, _} =
      Timelines.hashtag(name, MastodonCursor.parse(%{}, @feed_limit, 40), viewer_id: viewer_id)

    rendered = StatusJSON.render_many(posts, viewer_id)

    if connected?(socket), do: Streaming.subscribe(topic)

    {:ok,
     socket
     |> assign(:page_title, "##{name}")
     |> assign(:tag_name, name)
     |> assign(:topic, topic)
     |> assign(:post_count, length(rendered))
     |> stream(:posts, rendered, dom_id: &dom_id/1)}
  end

  @impl true
  def handle_event("favourite", %{"id" => id}, socket), do: react(socket, id, :favourite)
  def handle_event("reblog", %{"id" => id}, socket), do: react(socket, id, :reblog)

  defp react(socket, id, kind) do
    case AnglerWeb.Live.Interactions.toggle(socket.assigns.current_profile, id, kind) do
      {:ok, rendered} -> {:noreply, stream_insert(socket, :posts, rendered, dom_id: &dom_id/1)}
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:streaming, topic, "update", payload}, socket) do
    with true <- topic == socket.assigns.topic,
         {:ok, status} <- Jason.decode(payload) do
      {:noreply,
       socket
       |> stream_insert(:posts, status, at: 0, dom_id: &dom_id/1)
       |> update(:post_count, &(&1 + 1))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:streaming, topic, "delete", payload}, socket) do
    with true <- topic == socket.assigns.topic,
         {:ok, id} when is_binary(id) <- Jason.decode(payload) do
      {:noreply,
       socket
       |> stream_delete_by_dom_id(:posts, "post-" <> id)
       |> update(:post_count, &max(&1 - 1, 0))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp dom_id(status), do: "post-" <> status["id"]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <section class="space-y-5">
        <div class="flex items-center gap-3">
          <h1 class="text-3xl font-bold tracking-tight">#{@tag_name}</h1>
          <.link
            navigate={~p"/search?#{%{q: "##{@tag_name}", type: "hashtags"}}"}
            class="btn btn-ghost btn-xs"
          >
            <.icon name="hero-magnifying-glass-micro" class="size-4" /> Search
          </.link>
        </div>

        <div id="feed" phx-update="stream" class="space-y-3">
          <.post_card
            :for={{dom_id, status} <- @streams.posts}
            id={dom_id}
            status={status}
            current_user={@current_user}
          />
        </div>

        <p :if={@post_count == 0} class="text-sm text-base-content/60">
          No posts tagged #{@tag_name} yet.
        </p>
      </section>
    </Layouts.app>
    """
  end
end
