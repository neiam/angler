defmodule AnglerWeb.ProfileLive do
  @moduledoc """
  Public profile page at `/@:acct` — a local account's header, a tappable photo
  grid, and a scrollable feed of its posts. Grid tiles deep-link (anchor-scroll)
  to the matching card in the feed below.

  Visibility is owner-scoped: anonymous/other viewers see public posts only,
  while the profile owner gets All / Public / Unlisted filter tabs (so a silent
  import of unlisted posts is reachable) plus per-post controls to change a
  post's visibility. Remote accounts (`username@domain`) render from our cached
  copy with a "view original" link.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.PublicComponents

  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Statuses
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON

  @page_size 30

  @impl true
  def mount(%{"username" => acct}, _session, socket) do
    viewer_id = socket.assigns.current_profile && socket.assigns.current_profile.id

    case Profiles.lookup_acct(acct) do
      %Profile{} = profile ->
        owner? = is_integer(viewer_id) and viewer_id == profile.id and is_nil(profile.domain)
        filter = :all

        socket =
          socket
          |> assign(:page_title, "@#{profile.username}")
          |> assign(:profile, profile)
          |> assign(:account, Account.render(profile))
          |> assign(:remote?, not is_nil(profile.domain))
          |> assign(:owner?, owner?)
          |> assign(:filter, filter)
          |> load_first_page()

        {:ok, socket}

      nil ->
        {:ok,
         socket
         |> assign(:page_title, "Not found")
         |> assign(:profile, nil)
         |> assign(:account, nil)
         |> assign(:owner?, false)
         |> assign(:posts, [])
         |> assign(:has_more?, false)}
    end
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
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <header class="flex items-start gap-4">
        <.avatar account={@account} class="size-20" />
        <div class="min-w-0 flex-1">
          <h1 class="text-2xl font-bold truncate">{display_name(@account)}</h1>
          <div class="text-base-content/60">@{@account["acct"]}</div>
          <div :if={@profile.bio not in [nil, ""]} class="mt-2 prose prose-sm max-w-none break-words">
            {raw(@profile.bio)}
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
          </div>
        </div>
      </header>

      <div class="divider"></div>

      <%= cond do %>
        <% @profile.is_private and not @owner? -> %>
          <div class="text-center py-12 text-base-content/60">
            <.icon name="hero-lock-closed" class="size-6" />
            <p class="mt-2">This account is private.</p>
          </div>
        <% true -> %>
          <div :if={@owner?} class="tabs tabs-bordered mb-4" id="profile-filter-tabs">
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

          <%!-- Photo grid: tiles deep-link to the matching card in the feed below. --%>
          <div
            :if={Enum.any?(@posts, &has_media?/1)}
            id="profile-grid"
            class="grid grid-cols-3 gap-1 mb-6"
          >
            <a
              :for={post <- @posts}
              :if={has_media?(post)}
              href={"#post-#{post["id"]}"}
              class="relative block aspect-square overflow-hidden bg-base-200 group"
            >
              <img
                src={thumb(post)}
                alt=""
                loading="lazy"
                class="w-full h-full object-cover transition group-hover:opacity-90"
              />
              <span
                :if={post["visibility"] != "public"}
                class="absolute top-1 right-1 badge badge-xs badge-neutral opacity-80"
              >
                {post["visibility"]}
              </span>
            </a>
          </div>

          <%!-- Scrollable feed. Each card is an anchor target for its grid tile. --%>
          <div class="space-y-3" id="profile-feed">
            <div :for={post <- @posts} id={"post-#{post["id"]}"} class="scroll-mt-20">
              <div :if={@owner?} class="flex items-center gap-1 mb-1 text-xs text-base-content/60">
                <span class="mr-1">Visibility:</span>
                <button
                  :for={v <- ~w(public unlisted private)}
                  type="button"
                  class={[
                    "btn btn-xs",
                    if(post["visibility"] == v, do: "btn-primary", else: "btn-ghost")
                  ]}
                  phx-click="set_visibility"
                  phx-value-id={post["id"]}
                  phx-value-visibility={v}
                  disabled={post["visibility"] == v}
                >
                  {v}
                </button>
              </div>
              <.post_card status={post} current_user={@current_user} />
            </div>

            <p :if={@posts == []} class="text-sm text-base-content/60 text-center py-8">
              <%= if @owner? and @filter == :unlisted do %>
                No unlisted posts.
              <% else %>
                No posts yet.
              <% end %>
            </p>
          </div>

          <div :if={@has_more?} class="text-center mt-6">
            <button type="button" class="btn btn-outline btn-sm" phx-click="load_more">
              Load more
            </button>
          </div>
      <% end %>
    </Layouts.app>
    """
  end
end
