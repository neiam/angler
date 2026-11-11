defmodule AnglerWeb.IndexLive do
  @moduledoc """
  Public landing page: instance summary + stats, with a switchable live feed.
  Every feed shows photo and video posts only, as upstream's do.

    * **Mine** — the viewer's home timeline, the feed the mobile apps open on
      (`Timelines.home/3`, `user:<id>` stream). Logged-in only; boosts follow
      the viewer's web settings as they do in the Pixelfed app.
    * **Local** — local public posts (`public:local` stream)
    * **Known Network** — all public posts, local + federated (`public` stream)
    * **Trending** — `Trends.statuses/1` (static snapshot, no live updates)

  Local/Network seed from `Timelines.public/2` and stay current by subscribing
  to the matching streaming topic; switching feeds re-subscribes.

  Each feed is its own URL (`/mine`, `/`, `/network`, `/trending`, the live action),
  so tabs patch the address bar and can be linked to directly.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.PublicComponents

  alias Angler.Accounts.Settings
  alias Angler.Instance
  alias Angler.Pagination.MastodonCursor
  alias Angler.Streaming
  alias Angler.Timelines
  alias Angler.Trends
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON

  @feed_limit 30

  # {feed, label, path}
  @mine_feed {:mine, "Mine", "/mine"}
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
     |> assign(
       :feeds,
       if(socket.assigns.current_profile, do: [@mine_feed | @feeds], else: @feeds)
     )
     |> assign(:feed, nil)
     |> assign(:feed_topic, nil)
     |> assign(:boosters, %{})
     |> assign(:via_tags, %{})
     |> assign(:home_cursor, nil)
     |> stream(:posts, [], dom_id: &dom_id/1)}
  end

  # The feed follows the URL: first load, tab patches, and back/forward.
  @impl true
  def handle_params(_params, _uri, socket) do
    feed = socket.assigns.live_action

    cond do
      feed == :mine and is_nil(socket.assigns.current_profile) ->
        {:noreply, push_navigate(socket, to: ~p"/login?next=/mine")}

      feed == socket.assigns.feed ->
        {:noreply, socket}

      true ->
        switch_feed(socket, feed)
    end
  end

  defp switch_feed(socket, feed) do
    # Drop the previous live subscription before loading the new feed.
    if socket.assigns.feed_topic, do: Streaming.unsubscribe(socket.assigns.feed_topic)
    {socket, rendered} = load_feed(socket, feed, connected?(socket))
    {:noreply, stream(socket, :posts, rendered, reset: true, dom_id: &dom_id/1)}
  end

  @impl true
  def handle_event("favourite", %{"id" => id} = params, socket),
    do: react(socket, id, params["boost"], :favourite)

  def handle_event("reblog", %{"id" => id} = params, socket),
    do: react(socket, id, params["boost"], :reblog)

  # Mine only: the next page of the home timeline, below the oldest entry shown.
  def handle_event("load_more", _params, %{assigns: %{feed: :mine, home_cursor: max_id}} = socket)
      when is_integer(max_id) do
    {socket, rendered} = fetch_home(socket, max_id)
    {:noreply, stream(socket, :posts, rendered, dom_id: &dom_id/1)}
  end

  def handle_event("load_more", _params, socket), do: {:noreply, socket}

  # `boost_id` is set when the card is a boost (Mine feed): the stream item is
  # the wrapper, so the updated post goes back in under the booster.
  defp react(socket, id, boost_id, kind) do
    case AnglerWeb.Live.Interactions.toggle(socket.assigns.current_profile, id, kind) do
      {:ok, rendered} ->
        item =
          rendered
          |> tag_source(socket.assigns.via_tags)
          |> rewrap(boost_id, socket.assigns.boosters)

        {:noreply, stream_insert(socket, :posts, item, dom_id: &dom_id/1)}

      :error ->
        {:noreply, socket}
    end
  end

  defp tag_source(%{"id" => id} = rendered, via_tags) do
    case via_tags do
      %{^id => names} -> Map.put(rendered, "_via_tags", names)
      _ -> rendered
    end
  end

  defp rewrap(rendered, boost_id, boosters) do
    case boosters do
      %{^boost_id => booster} -> %{"id" => boost_id, "account" => booster, "reblog" => rendered}
      _ -> rendered
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
  defp load_feed(socket, :mine, connected?) do
    topic = "user:#{socket.assigns.current_profile.id}"
    if connected?, do: Streaming.subscribe(topic)

    socket =
      socket
      |> assign(:feed, :mine)
      |> assign(:feed_topic, topic)
      |> assign(:post_count, 0)
      |> assign(:boosters, %{})
      |> assign(:via_tags, %{})

    fetch_home(socket, nil)
  end

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
      |> assign(:home_cursor, nil)

    {socket, rendered}
  end

  # One page of the viewer's home timeline older than `max_id` (a
  # `home_feed_entries` id; nil for the newest). Boost options mirror what the
  # Pixelfed app asks for, so this matches what the viewer sees on their phone.
  defp fetch_home(socket, max_id) do
    profile = socket.assigns.current_profile
    web = Settings.get(socket.assigns.current_user.id).web || %{}

    opts = [
      include_reblogs: web["enable_reblogs"] == true,
      photos_reblogs_only: web["photo_reblogs_only"] == true
    ]

    cursor = MastodonCursor.parse(%{"max_id" => max_id && to_string(max_id)}, @feed_limit, 40)
    {posts, cursor_rows} = Timelines.home(profile.id, cursor, opts)

    # Posts here only through a followed hashtag carry `"_via_tags"`, which
    # `post_card` shows as a "via #tag" line; kept in an assign so a re-render
    # after a like or boost keeps it.
    via_tags =
      for {id, names} <- Timelines.home_tag_sources(profile.id, posts),
          into: socket.assigns.via_tags,
          do: {Integer.to_string(id), names}

    rendered =
      posts
      |> StatusJSON.render_many(profile.id, context: "home")
      |> Enum.map(&tag_source(&1, via_tags))

    boosters =
      for %{"id" => id, "reblog" => %{}, "account" => booster} <- rendered,
          into: socket.assigns.boosters,
          do: {id, booster}

    socket =
      socket
      |> assign(:boosters, boosters)
      |> assign(:via_tags, via_tags)
      |> assign(:home_cursor, cursor_rows |> Enum.map(& &1.id) |> Enum.min(fn -> nil end))
      |> update(:post_count, &(&1 + length(rendered)))

    {socket, rendered}
  end

  defp fetch(:local) do
    {posts, _} = Timelines.public(MastodonCursor.parse(%{}, @feed_limit, 40), local_only: true)
    {posts, "public:local"}
  end

  defp fetch(:network) do
    {posts, _} = Timelines.public(MastodonCursor.parse(%{}, @feed_limit, 40), [])
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

  defp empty_label(:mine), do: "Nothing here yet. Follow some people to fill your feed."
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
              :if={key in [:mine, :local, :network] && @feed == key}
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

        <div :if={@feed == :mine and @home_cursor} class="pt-2 text-center">
          <button
            id="feed-load-more"
            type="button"
            phx-click="load_more"
            phx-disable-with="Loading…"
            class="btn btn-outline btn-sm"
          >
            Load more
          </button>
        </div>
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
