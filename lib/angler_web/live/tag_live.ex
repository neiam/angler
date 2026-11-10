defmodule AnglerWeb.TagLive do
  @moduledoc """
  Hashtag timeline at `/tags/:name` — public/unlisted posts tagged with
  `:name`, seeded from `Timelines.hashtag/3` and kept current by subscribing to
  the `"hashtag:<name>"` streaming topic. This is the destination for hashtag
  results in `AnglerWeb.SearchLive` and the navbar type-ahead.

  `/tags/:name/mason` swaps the single column for a wide, multi-column masonry
  wall, and `/tags/:name/mason/clean` also hides caption text to leave just
  the photos. The toggles patch between these routes, so each view is
  deep-linkable.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.PublicComponents

  alias Angler.Hashtags
  alias Angler.Hashtags.Following
  alias Angler.Pagination.MastodonCursor
  alias Angler.Streaming
  alias Angler.Timelines
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.MetaTags

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
     |> assign(:meta, MetaTags.tag(name, rendered))
     |> assign(:tag_name, name)
     |> assign(:topic, topic)
     |> assign(:following?, following?(profile, name))
     |> assign(:post_count, length(rendered))
     |> stream(:posts, rendered, dom_id: &dom_id/1)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    action = socket.assigns.live_action

    {:noreply,
     socket
     |> assign(:masonry?, action in [:mason, :clean])
     |> assign(:captions?, action != :clean)}
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
          <.link id="all-tags-link" navigate={~p"/tags"} class="btn btn-ghost btn-xs">
            <.icon name="hero-hashtag-micro" class="size-4" /> Popular tags
          </.link>

          <div class="ml-auto flex items-center gap-2">
            <.captions_toggle
              :if={@masonry?}
              path={
                if @captions?,
                  do: ~p"/tags/#{@tag_name}/mason/clean",
                  else: ~p"/tags/#{@tag_name}/mason"
              }
              captions?={@captions?}
            />
            <.layout_toggle
              id="layout-toggle"
              options={[
                %{
                  id: "layout-list",
                  path: ~p"/tags/#{@tag_name}",
                  label: "List",
                  icon: "hero-bars-3-bottom-left-micro",
                  active?: not @masonry?
                },
                %{
                  id: "layout-masonry",
                  path:
                    if(@captions?,
                      do: ~p"/tags/#{@tag_name}/mason",
                      else: ~p"/tags/#{@tag_name}/mason/clean"
                    ),
                  label: "Masonry",
                  icon: "hero-view-columns-micro",
                  active?: @masonry?
                }
              ]}
            />
          </div>
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
end
