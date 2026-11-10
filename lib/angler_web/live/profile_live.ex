defmodule AnglerWeb.ProfileLive do
  @moduledoc """
  Public profile page at `/@:acct` — an account's header and its posts in one
  of three layouts, each its own URL so it can be linked to:

    * `/@:acct` — a compact square grid (text posts as caption tiles)
    * `/@:acct/feed` — the stacked feed of full post cards
    * `/@:acct/mason` — a wide masonry wall of cards, as on tag pages;
      `/@:acct/mason/clean` also hides captions

  Grid tiles link to the post's own page (`/p/:username/:id`), as do the cards'
  timestamps.

  Visibility is owner-scoped: anonymous/other viewers see public posts only,
  while the profile owner gets All / Public / Unlisted filter tabs (so a silent
  import of unlisted posts is reachable) plus per-post controls to change a
  post's visibility. Remote accounts (`username@domain`) render from our cached
  copy with a "view original" link; admins also get "Fetch older posts", which
  backfills the account's history from its outbox (`Angler.Federation.Backfill`).
  """
  use AnglerWeb, :live_view

  import AnglerWeb.PublicComponents

  alias Angler.Federation.Workers.Backfill, as: BackfillWorker
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Statuses
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.MetaTags

  @page_size 30

  @impl true
  def mount(%{"username" => acct}, _session, socket) do
    viewer_id = socket.assigns.current_profile && socket.assigns.current_profile.id

    case Profiles.lookup_acct(acct) do
      %Profile{} = profile ->
        owner? = is_integer(viewer_id) and viewer_id == profile.id and is_nil(profile.domain)
        filter = :all

        account = Account.render(profile)

        socket =
          socket
          |> assign(:page_title, "@#{profile.username}")
          |> assign(:profile, profile)
          |> assign(:account, account)
          |> assign(:acct, acct)
          |> assign(:meta, MetaTags.profile(account, "/@#{acct}"))
          |> assign(:remote?, not is_nil(profile.domain))
          |> assign(:owner?, owner?)
          |> assign(:filter, filter)
          |> assign(:backfill?, backfill_allowed?(socket, profile))
          |> assign(:backfilling?, false)
          |> load_first_page()

        if socket.assigns.backfill? and connected?(socket),
          do: Phoenix.PubSub.subscribe(Angler.PubSub, BackfillWorker.topic(profile.id))

        {:ok, socket}

      nil ->
        {:ok,
         socket
         |> assign(:page_title, "Not found")
         |> assign(:profile, nil)
         |> assign(:account, nil)
         |> assign(:owner?, false)
         |> assign(:acct, acct)
         |> assign(:posts, [])
         |> assign(:has_more?, false)}
    end
  end

  # The layout follows the URL (toggle patches, back/forward); the posts loaded
  # so far carry over between layouts.
  @impl true
  def handle_params(_params, _uri, socket) do
    layout = socket.assigns.live_action

    {:noreply,
     socket
     |> assign(:view, layout)
     |> assign(:masonry?, layout in [:mason, :clean])
     |> assign(:captions?, layout != :clean)}
  end

  @impl true
  def handle_event("favourite", %{"id" => id}, socket), do: react(socket, id, :favourite)
  def handle_event("reblog", %{"id" => id}, socket), do: react(socket, id, :reblog)

  # Owner-only filter tabs.
  def handle_event("filter", %{"filter" => f}, %{assigns: %{owner?: true}} = socket) do
    filter = parse_filter(f)
    {:noreply, socket |> assign(:filter, filter) |> load_first_page()}
  end

  def handle_event("filter", _params, socket), do: {:noreply, socket}

  def handle_event("load_more", _params, socket) do
    %{profile: profile, filter: filter, posts: posts} = socket.assigns
    viewer_id = viewer_id(socket)

    max_id =
      case List.last(posts) do
        %{"id" => id} -> String.to_integer(id)
        _ -> nil
      end

    {more, has_more?} = fetch_page(profile, filter, viewer_id, max_id)
    {:noreply, socket |> assign(:posts, posts ++ more) |> assign(:has_more?, has_more?)}
  end

  # Owner-only: change a post's visibility (e.g. unlisted -> public).
  def handle_event(
        "set_visibility",
        %{"id" => id, "visibility" => vis},
        %{assigns: %{owner?: true}} = socket
      ) do
    with {visibility, _} when visibility in [:public, :unlisted, :private] <-
           {parse_visibility(vis), :ok},
         {:ok, _updated} <-
           Statuses.set_visibility(
             String.to_integer(id),
             socket.assigns.current_profile,
             visibility
           ) do
      posts =
        Enum.map(socket.assigns.posts, fn p ->
          if p["id"] == id, do: Map.put(p, "visibility", Atom.to_string(visibility)), else: p
        end)

      {:noreply, socket |> assign(:posts, posts) |> put_flash(:info, "Visibility updated.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Couldn't update visibility.")}
    end
  end

  def handle_event("set_visibility", _params, socket), do: {:noreply, socket}

  # Admin-only: pull the remote account's older posts from its outbox.
  def handle_event("backfill", _params, %{assigns: %{backfill?: true}} = socket) do
    case BackfillWorker.enqueue(socket.assigns.profile.id) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:backfilling?, true)
         |> put_flash(:info, "Fetching older posts from #{socket.assigns.profile.domain}…")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't queue the fetch.")}
    end
  end

  def handle_event("backfill", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:backfill_done, result}, socket) do
    socket = assign(socket, :backfilling?, false)

    socket =
      case result do
        {:ok, %{imported: n} = r} ->
          profile = Profiles.get_profile(socket.assigns.profile.id) || socket.assigns.profile

          socket
          |> assign(:profile, profile)
          |> load_first_page()
          |> put_flash(:info, backfill_summary(n, r))

        {:error, reason} ->
          put_flash(socket, :error, "Couldn't read their outbox (#{backfill_reason(reason)}).")
      end

    {:noreply, socket}
  end

  defp backfill_allowed?(socket, %Profile{domain: domain}) do
    match?(%{is_admin: true}, socket.assigns.current_user) and not is_nil(domain)
  end

  defp backfill_summary(0, %{existing: e}),
    do: "No older posts found (#{e} already here)."

  defp backfill_summary(n, %{existing: e, failed: f}) do
    "Imported #{n} older #{if n == 1, do: "post", else: "posts"}" <>
      if(e > 0, do: ", #{e} already here", else: "") <>
      if(f > 0, do: ", #{f} failed", else: "") <> "."
  end

  defp backfill_reason({:unavailable, status}), do: "server answered #{status}"
  defp backfill_reason(:bad_status), do: "server refused"
  defp backfill_reason(:no_outbox), do: "no outbox published"
  defp backfill_reason(reason) when is_atom(reason), do: Phoenix.Naming.humanize(reason)
  defp backfill_reason(_), do: "unreachable"

  ## Internals

  defp viewer_id(socket),
    do: socket.assigns.current_profile && socket.assigns.current_profile.id

  defp load_first_page(socket) do
    %{profile: profile, filter: filter} = socket.assigns

    if hidden_profile?(socket) do
      socket |> assign(:posts, []) |> assign(:has_more?, false)
    else
      {posts, has_more?} = fetch_page(profile, filter, viewer_id(socket), nil)
      socket |> assign(:posts, posts) |> assign(:has_more?, has_more?)
    end
  end

  # Private accounts hide posts from everyone but the owner.
  defp hidden_profile?(%{assigns: %{profile: profile, owner?: owner?}}),
    do: profile.is_private and not owner?

  defp fetch_page(profile, filter, viewer_id, max_id) do
    rows =
      Statuses.list_for_profile_page(profile.id,
        viewer_id: viewer_id,
        filter: filter,
        max_id: max_id,
        limit: @page_size
      )

    {StatusJSON.render_many(rows, viewer_id), length(rows) == @page_size}
  end

  defp react(socket, id, kind) do
    case AnglerWeb.Live.Interactions.toggle(socket.assigns.current_profile, id, kind) do
      {:ok, rendered} ->
        posts =
          Enum.map(socket.assigns.posts, fn p ->
            if p["id"] == rendered["id"], do: rendered, else: p
          end)

        {:noreply, assign(socket, :posts, posts)}

      :error ->
        {:noreply, socket}
    end
  end

  defp parse_filter("public"), do: :public
  defp parse_filter("unlisted"), do: :unlisted
  defp parse_filter(_), do: :all

  defp parse_visibility("public"), do: :public
  defp parse_visibility("unlisted"), do: :unlisted
  defp parse_visibility("private"), do: :private
  defp parse_visibility(_), do: :invalid

  defp has_media?(%{"media_attachments" => [_ | _]}), do: true
  defp has_media?(_), do: false

  defp thumb(%{"media_attachments" => [m | _]}), do: m["preview_url"] || m["url"]
  defp thumb(_), do: nil

  defp multi_media?(%{"media_attachments" => [_, _ | _]}), do: true
  defp multi_media?(_), do: false

  defp video?(%{"media_attachments" => [%{"type" => t} | _]}), do: t in ["video", "gifv"]
  defp video?(_), do: false

  defp post_path(%{"account" => %{"username" => username}, "id" => id}),
    do: ~p"/p/#{username}/#{id}"

  defp layout_path(acct, :grid), do: ~p"/@#{acct}"
  defp layout_path(acct, :list), do: ~p"/@#{acct}/feed"
  defp layout_path(acct, :mason), do: ~p"/@#{acct}/mason"
  defp layout_path(acct, :clean), do: ~p"/@#{acct}/mason/clean"

  defp layout_options(acct, layout, captions?) do
    [
      %{id: "layout-grid", layout: :grid, label: "Grid", icon: "hero-squares-2x2-micro"},
      %{id: "layout-list", layout: :list, label: "List", icon: "hero-bars-3-bottom-left-micro"},
      %{
        id: "layout-masonry",
        layout: if(captions?, do: :mason, else: :clean),
        label: "Masonry",
        icon: "hero-view-columns-micro"
      }
    ]
    |> Enum.map(fn opt ->
      active? =
        case opt.layout do
          l when l in [:mason, :clean] -> layout in [:mason, :clean]
          l -> l == layout
        end

      opt |> Map.put(:path, layout_path(acct, opt.layout)) |> Map.put(:active?, active?)
    end)
  end

  @impl true
  def render(%{profile: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="text-center py-16 space-y-2">
        <h1 class="text-2xl font-bold">Account not found</h1>
        <p class="text-base-content/60">No local account matches that username.</p>
        <.link navigate={~p"/"} class="btn btn-ghost btn-sm mt-2">Back home</.link>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_profile={@current_profile}
      wide={@masonry?}
    >
      <div class={[@masonry? && "mx-auto max-w-[110rem] space-y-4 px-4 py-10 sm:px-6 lg:px-8"]}>
        <.profile_header
          account={@account}
          profile={@profile}
          remote?={@remote?}
          backfill?={@backfill?}
          backfilling?={@backfilling?}
        />

        <div class="divider"></div>

        <%= if @profile.is_private and not @owner? do %>
          <div class="text-center py-12 text-base-content/60">
            <.icon name="hero-lock-closed" class="size-6" />
            <p class="mt-2">This account is private.</p>
          </div>
        <% else %>
          <div class="mb-4 flex flex-wrap items-center gap-3">
            <div :if={@owner?} class="tabs tabs-bordered" id="profile-filter-tabs">
              <button
                :for={{label, value} <- [{"All", :all}, {"Public", :public}, {"Unlisted", :unlisted}]}
                type="button"
                class={["tab", @filter == value && "tab-active"]}
                phx-click="filter"
                phx-value-filter={value}
              >
                {label}
              </button>
            </div>

            <div class="ml-auto flex items-center gap-2">
              <.captions_toggle
                :if={@masonry?}
                path={layout_path(@acct, if(@captions?, do: :clean, else: :mason))}
                captions?={@captions?}
              />
              <.layout_toggle
                id="layout-toggle"
                options={layout_options(@acct, @view, @captions?)}
              />
            </div>
          </div>

          <%= case @view do %>
            <% :grid -> %>
              <.post_grid posts={@posts} />
            <% :list -> %>
              <div class="space-y-3" id="profile-feed">
                <div :for={post <- @posts} id={"post-#{post["id"]}"}>
                  <.visibility_controls :if={@owner?} post={post} />
                  <.post_card status={post} current_user={@current_user} />
                </div>
              </div>
            <% _masonry -> %>
              <%!-- CSS columns, as on tag pages (`.masonry-feed` in app.css). --%>
              <div
                id="profile-masonry"
                class={[
                  "masonry-feed gap-3 sm:columns-2 lg:columns-3 2xl:columns-4",
                  not @captions? && "hide-captions"
                ]}
              >
                <.post_card
                  :for={post <- @posts}
                  id={"post-#{post["id"]}"}
                  status={post}
                  current_user={@current_user}
                />
              </div>
          <% end %>

          <p :if={@posts == []} class="text-sm text-base-content/60 text-center py-8">
            <%= if @owner? and @filter == :unlisted do %>
              No unlisted posts.
            <% else %>
              No posts yet.
            <% end %>
          </p>

          <div :if={@has_more?} class="text-center mt-6">
            <button
              id="profile-load-more"
              type="button"
              class="btn btn-outline btn-sm"
              phx-click="load_more"
              phx-disable-with="Loading…"
            >
              Load more
            </button>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # Compact square grid. Every tile links to the post's page; text-only posts
  # get a caption tile so nothing on the profile is left out.
  attr :posts, :list, required: true

  defp post_grid(assigns) do
    ~H"""
    <div :if={@posts != []} id="profile-grid" class="grid grid-cols-3 gap-1">
      <.link
        :for={post <- @posts}
        id={"tile-#{post["id"]}"}
        navigate={post_path(post)}
        class="group relative block aspect-square overflow-hidden bg-base-200"
      >
        <%= if has_media?(post) do %>
          <img
            src={thumb(post)}
            alt=""
            loading="lazy"
            class={[
              "h-full w-full object-cover transition duration-300 group-hover:scale-[1.03] group-hover:brightness-105",
              post["sensitive"] && "blur-lg"
            ]}
          />
        <% else %>
          <div class="flex h-full w-full items-center p-3 text-xs leading-snug text-base-content/80 sm:p-4 sm:text-sm transition-colors group-hover:bg-base-300">
            <p class="line-clamp-6 break-words">{post["content_text"]}</p>
          </div>
        <% end %>
        <span class="pointer-events-none absolute right-1.5 top-1.5 flex items-center gap-1 text-white drop-shadow">
          <.icon :if={video?(post)} name="hero-play-solid" class="size-4" />
          <.icon :if={multi_media?(post)} name="hero-square-2-stack-solid" class="size-4" />
        </span>
        <span
          :if={post["visibility"] != "public"}
          class="absolute bottom-1 left-1 badge badge-xs badge-neutral opacity-80"
        >
          {post["visibility"]}
        </span>
      </.link>
    </div>
    """
  end

  # Owner-only: move a post between public / unlisted / private.
  attr :post, :map, required: true

  defp visibility_controls(assigns) do
    ~H"""
    <div class="flex items-center gap-1 mb-1 text-xs text-base-content/60">
      <span class="mr-1">Visibility:</span>
      <button
        :for={v <- ~w(public unlisted private)}
        type="button"
        class={["btn btn-xs", if(@post["visibility"] == v, do: "btn-primary", else: "btn-ghost")]}
        phx-click="set_visibility"
        phx-value-id={@post["id"]}
        phx-value-visibility={v}
        disabled={@post["visibility"] == v}
      >
        {v}
      </button>
    </div>
    """
  end

  attr :account, :map, required: true
  attr :profile, :map, required: true
  attr :remote?, :boolean, required: true
  attr :backfill?, :boolean, required: true
  attr :backfilling?, :boolean, required: true

  defp profile_header(assigns) do
    ~H"""
    <header class="flex items-start gap-4">
      <.avatar account={@account} class="size-20" />
      <div class="min-w-0 flex-1">
        <h1 class="text-2xl font-bold truncate">{display_name(@account)}</h1>
        <div class="text-base-content/60">@{@account["acct"]}</div>
        <div :if={@profile.bio not in [nil, ""]} class="mt-2 prose prose-sm max-w-none break-words">
          {raw(
            if(@profile.domain,
              do: Angler.Content.RemoteHtml.clean(@profile.bio),
              else: @profile.bio
            )
          )}
        </div>
        <div class="mt-3 flex flex-wrap items-center gap-4 text-sm text-base-content/70">
          <span>
            <span class="font-semibold text-base-content">{@profile.statuses_count}</span> posts
          </span>
          <%= if @remote? do %>
            <span>
              <span class="font-semibold text-base-content">{@profile.followers_count}</span>
              followers
            </span>
            <span>
              <span class="font-semibold text-base-content">{@profile.following_count}</span>
              following
            </span>
          <% else %>
            <.link navigate={~p"/@#{@profile.username}/followers"} class="hover:text-base-content">
              <span class="font-semibold text-base-content">{@profile.followers_count}</span>
              followers
            </.link>
            <.link navigate={~p"/@#{@profile.username}/following"} class="hover:text-base-content">
              <span class="font-semibold text-base-content">{@profile.following_count}</span>
              following
            </.link>
          <% end %>
        </div>
        <div :if={@remote?} class="mt-2">
          <a
            href={@account["url"]}
            target="_blank"
            rel="noopener"
            class="link link-primary text-sm inline-flex items-center gap-1"
          >
            <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" />
            View original on {@profile.domain}
          </a>
          <button
            :if={@backfill?}
            id="backfill-posts"
            type="button"
            phx-click="backfill"
            disabled={@backfilling?}
            title="Admin: pull this account's older public posts from its outbox"
            class="btn btn-ghost btn-xs ml-2 gap-1"
          >
            <.icon
              name={if @backfilling?, do: "hero-arrow-path-micro", else: "hero-clock-micro"}
              class={["size-4", @backfilling? && "animate-spin"]}
            />
            {if @backfilling?, do: "Fetching older posts…", else: "Fetch older posts"}
          </button>
        </div>
      </div>
    </header>
    """
  end
end
