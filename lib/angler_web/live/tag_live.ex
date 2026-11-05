defmodule AnglerWeb.TagLive do
  @moduledoc """
  Hashtag timeline at `/tags/:name` — public/unlisted posts tagged with
  `:name`, seeded from `Timelines.hashtag/3` and kept current by subscribing to
  the `"hashtag:<name>"` streaming topic. This is the destination for hashtag
  results in `AnglerWeb.SearchLive` and the navbar type-ahead.

  `?layout=masonry` swaps the single column for a wide, multi-column masonry
  wall, and in masonry `&captions=off` hides caption text to leave just the
  photos. Both toggles patch the URL so the view is deep-linkable.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.PublicComponents

  alias Angler.Hashtags
  alias Angler.Hashtags.Following
  alias Angler.Pagination.MastodonCursor
  alias Angler.Streaming
  alias Angler.Timelines
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON

  @feed_limit 30

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    name = name |> String.downcase() |> String.trim_leading("#")
    topic = "hashtag:#{name}"

    profile = socket.assigns.current_profile
    viewer_id = profile && profile.id

    {posts, _} =
      Timelines.hashtag(name, MastodonCursor.parse(%{}, @feed_limit, 40),
        viewer_id: viewer_id,
        only_media: true
      )

    rendered = StatusJSON.render_many(posts, viewer_id)

    if connected?(socket), do: Streaming.subscribe(topic)

    {:ok,
     socket
     |> assign(:page_title, "##{name}")
     |> assign(:tag_name, name)
     |> assign(:topic, topic)
     |> assign(:following?, following?(profile, name))
     |> assign(:post_count, length(rendered))
     |> stream(:posts, rendered, dom_id: &dom_id/1)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:masonry?, params["layout"] == "masonry")
     |> assign(:captions?, params["captions"] != "off")}
  end

  @impl true
  def handle_event("follow_tag", _params, socket) do
    case socket.assigns.current_profile do
      nil ->
        {:noreply, push_navigate(socket, to: ~p"/login?next=/tags/#{socket.assigns.tag_name}")}

      profile ->
        {:ok, _tag} = Following.follow(profile, socket.assigns.tag_name)
        {:noreply, assign(socket, :following?, true)}
    end
  end

  def handle_event("unfollow_tag", _params, socket) do
    if profile = socket.assigns.current_profile do
      :ok = Following.unfollow(profile, socket.assigns.tag_name)
    end

    {:noreply, assign(socket, :following?, false)}
  end

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

  defp following?(nil, _name), do: false

  defp following?(profile, name) do
    case Hashtags.get_by_name(name) do
      nil -> false
      tag -> Following.following?(profile.id, tag.id)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_profile={@current_profile}
      wide={@masonry?}
    >
      <section class={[
        "space-y-5",
        @masonry? && "mx-auto max-w-[110rem] px-4 py-10 sm:px-6 lg:px-8"
      ]}>
        <div class="flex flex-wrap items-center gap-3">
          <h1 class="text-3xl font-bold tracking-tight">#{@tag_name}</h1>
          <button
            :if={@current_profile}
            type="button"
            class={["btn btn-sm", if(@following?, do: "btn-outline", else: "btn-primary")]}
            phx-click={if @following?, do: "unfollow_tag", else: "follow_tag"}
          >
            <.icon
              name={if @following?, do: "hero-check-micro", else: "hero-plus-micro"}
              class="size-4"
            />
            {if @following?, do: "Following", else: "Follow"}
          </button>
          <.link
            navigate={~p"/search?#{%{q: "##{@tag_name}", type: "hashtags"}}"}
            class="btn btn-ghost btn-xs"
          >
            <.icon name="hero-magnifying-glass-micro" class="size-4" /> Search
          </.link>

          <div
            id="layout-toggle"
            role="group"
            aria-label="Layout"
            class="ml-auto inline-flex rounded-field border border-base-300 bg-base-200 p-0.5"
          >
            <.link
              id="layout-list"
              patch={tag_path(@tag_name, false, @captions?)}
              replace
              title="List"
              aria-label="List layout"
              aria-pressed={to_string(not @masonry?)}
              class={layout_button_class(not @masonry?)}
            >
              <.icon name="hero-bars-3-bottom-left-micro" class="size-4" />
            </.link>
            <.link
              id="layout-masonry"
              patch={tag_path(@tag_name, true, @captions?)}
              replace
              title="Masonry"
              aria-label="Masonry layout"
              aria-pressed={to_string(@masonry?)}
              class={layout_button_class(@masonry?)}
            >
              <.icon name="hero-squares-2x2-micro" class="size-4" />
            </.link>
          </div>

          <.link
            :if={@masonry?}
            id="captions-toggle"
            patch={tag_path(@tag_name, true, not @captions?)}
            replace
            title={if @captions?, do: "Hide captions", else: "Show captions"}
            aria-pressed={to_string(@captions?)}
            class={[
              "btn btn-sm gap-1.5",
              if(@captions?, do: "btn-ghost", else: "btn-outline")
            ]}
          >
            <.icon
              name={
                if @captions?,
                  do: "hero-chat-bubble-bottom-center-text-micro",
                  else: "hero-photo-micro"
              }
              class="size-4"
            />
            {if @captions?, do: "Captions", else: "Photos only"}
          </.link>
        </div>

        <%!-- Masonry is CSS columns: cards keep their natural height and flow
             top-to-bottom, so stream inserts and deletes need no JS. Captions
             are hidden by a class here too, since streamed cards aren't
             re-rendered when an assign changes. --%>
        <div
          id="feed"
          phx-update="stream"
          class={[
            if(@masonry?,
              do: "masonry-feed gap-3 sm:columns-2 lg:columns-3 2xl:columns-4",
              else: "space-y-3"
            ),
            (@masonry? and not @captions?) && "hide-captions"
          ]}
        >
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

  # `captions=off` rides along in list view (where it has no effect) so a
  # round trip back to masonry keeps it.
  defp tag_path(name, masonry?, captions?) do
    query =
      Enum.reject([layout: masonry? && "masonry", captions: !captions? && "off"], fn {_, v} ->
        v == false
      end)

    if query == [], do: ~p"/tags/#{name}", else: ~p"/tags/#{name}?#{query}"
  end

  defp layout_button_class(active?) do
    [
      "inline-flex items-center justify-center rounded-[calc(var(--radius-field)-2px)] px-2 py-1 transition-colors",
      if(active?,
        do: "bg-base-100 text-base-content shadow-sm",
        else: "text-base-content/60 hover:text-base-content"
      )
    ]
  end
end
