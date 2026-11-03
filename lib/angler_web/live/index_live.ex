defmodule AnglerWeb.IndexLive do
  @moduledoc """
  Public landing page: instance summary + stats, with a switchable live feed.
  Every feed shows photo and video posts only, as upstream's do.

    * **Local** — local public posts (`public:local` stream)
    * **Known Network** — all public posts, local + federated (`public` stream)
    * **Trending** — `Trends.statuses/1` (static snapshot, no live updates)

  Local/Network seed from `Timelines.public/2` and stay current by subscribing
  to the matching streaming topic; switching feeds re-subscribes.

  Each feed is its own URL (`/`, `/network`, `/trending`, the live action),
  so tabs patch the address bar and can be linked to directly.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.PublicComponents

  alias Angler.Instance
  alias Angler.Pagination.MastodonCursor
  alias Angler.Streaming
  alias Angler.Timelines
  alias Angler.Trends
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON

  @feed_limit 30

  # {feed, label, path}
  @feeds [
    {:local, "Local", "/"},
    {:network, "Known Network", "/network"},
    {:trending, "Trending", "/trending"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, Instance.title())
     |> assign(:stats, Instance.stats())
     |> assign(:instance, instance_meta())
     |> assign(:registration, registration_state())
     |> assign(:feeds, @feeds)
     |> assign(:feed, nil)
     |> assign(:feed_topic, nil)
     |> stream(:posts, [], dom_id: &dom_id/1)}
  end

  # The feed follows the URL: first load, tab patches, and back/forward.
  @impl true
  def handle_params(_params, _uri, socket) do
    feed = socket.assigns.live_action

    if feed == socket.assigns.feed do
      {:noreply, socket}
    else
      # Drop the previous live subscription before loading the new feed.
      if socket.assigns.feed_topic, do: Streaming.unsubscribe(socket.assigns.feed_topic)
      {socket, rendered} = load_feed(socket, feed, connected?(socket))
      {:noreply, stream(socket, :posts, rendered, reset: true, dom_id: &dom_id/1)}
    end
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
    if topic == socket.assigns.feed_topic do
      case Jason.decode(payload) do
        # Photo and video posts only, like the seeded feed.
        {:ok, %{"media_attachments" => [_ | _]} = status} ->
          {:noreply,
           socket
           |> stream_insert(:posts, status, at: 0, dom_id: &dom_id/1)
           |> update(:post_count, &(&1 + 1))}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:streaming, topic, "delete", payload}, socket) do
    with true <- topic == socket.assigns.feed_topic,
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

  ## Internals

  # Returns {socket-with-feed-assigns, rendered_posts}.
  defp load_feed(socket, feed, connected?) do
    {posts, topic} = fetch(feed)
    if connected? and topic, do: Streaming.subscribe(topic)
    viewer_id = socket.assigns.current_profile && socket.assigns.current_profile.id
    rendered = StatusJSON.render_many(posts, viewer_id, context: "public")

    socket =
      socket
      |> assign(:feed, feed)
      |> assign(:feed_topic, topic)
      |> assign(:post_count, length(rendered))

    {socket, rendered}
  end

  defp fetch(:local) do
    {posts, _} =
      Timelines.public(MastodonCursor.parse(%{}, @feed_limit, 40),
        local_only: true,
        only_media: true
      )

    {posts, "public:local"}
  end

  defp fetch(:network) do
    {posts, _} = Timelines.public(MastodonCursor.parse(%{}, @feed_limit, 40), only_media: true)
    {posts, "public"}
  end

  defp fetch(:trending), do: {Trends.statuses(@feed_limit, only_media: true), nil}

  defp dom_id(status), do: "post-" <> status["id"]

  defp instance_meta do
    %{
      title: Instance.title(),
      short_description: Instance.short_description(),
      contact_email: Instance.contact_email()
    }
  end

  defp registration_state do
    %{
      open?: Instance.open_registration?(),
      approval?: Instance.approval_required?(),
      curated?: Instance.curated_registration?()
    }
  end

  defp empty_label(:local), do: "No local posts yet."
  defp empty_label(:network), do: "No federated posts yet."
  defp empty_label(:trending), do: "Nothing trending right now."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <section class="space-y-5">
        <div class="space-y-2">
          <h1 class="text-3xl font-bold tracking-tight">{@instance.title}</h1>
          <p class="text-base-content/70">{@instance.short_description}</p>
        </div>

        <div class="grid grid-cols-3 gap-3">
          <.stat label="Users" value={@stats.user_count} />
          <.stat label="Posts" value={@stats.status_count} />
          <.stat label="Known servers" value={@stats.domain_count} />
        </div>

        <div :if={!@current_user} class="flex flex-wrap items-center gap-3">
          <%= cond do %>
            <% @registration.open? -> %>
              <.link navigate={~p"/register"} class="btn btn-primary btn-sm">Create an account</.link>
              <span :if={@registration.approval?} class="text-xs text-base-content/60">
                New accounts require operator approval.
              </span>
            <% @registration.curated? -> %>
              <.link
                id="index-apply"
                navigate={~p"/auth/sign_up"}
                class="btn btn-primary btn-sm"
              >
                Apply for an account
              </.link>
            <% true -> %>
              <span class="text-sm text-base-content/60">Registration is currently closed.</span>
          <% end %>
          <.link navigate={~p"/login"} class="btn btn-ghost btn-sm">
            Log in
          </.link>
        </div>

        <div class="grid grid-cols-2 gap-3">
          <.link navigate={~p"/about"} class="btn btn-outline w-full">About this server</.link>
          <.link navigate={~p"/features"} class="btn btn-outline w-full">Features</.link>
        </div>
      </section>

      <section class="mt-8 space-y-3">
        <div role="tablist" class="tabs tabs-bordered">
          <.link
            :for={{key, label, path} <- @feeds}
            id={"feed-tab-#{key}"}
            patch={path}
            role="tab"
            aria-selected={to_string(@feed == key)}
            class={["tab", @feed == key && "tab-active font-semibold"]}
          >
            {label}
            <span
              :if={key in [:local, :network] && @feed == key}
              class="ml-2 inline-block size-2 rounded-full bg-success motion-safe:animate-pulse"
            />
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

        <p :if={@post_count == 0} class="text-sm text-base-content/60">{empty_label(@feed)}</p>
      </section>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp stat(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body items-center p-4">
        <div class="text-2xl font-bold tabular-nums">{@value}</div>
        <div class="text-xs uppercase tracking-wide text-base-content/60">{@label}</div>
      </div>
    </div>
    """
  end
end
