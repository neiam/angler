defmodule AnglerWeb.ProfileLive do
  @moduledoc """
  Public profile page at `/@:acct` — a local account's header plus its latest
  public posts. Remote accounts (`username@domain`) resolve to the same page
  rendered from our cached copy, with a "view original" link to their origin.
  Anonymous-safe: private accounts show a locked notice and no posts.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.PublicComponents

  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Statuses
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON

  @impl true
  def mount(%{"username" => acct}, _session, socket) do
    viewer_id = socket.assigns.current_profile && socket.assigns.current_profile.id

    case Profiles.lookup_acct(acct) do
      %Profile{} = profile ->
        account = Account.render(profile)

        posts =
          if profile.is_private do
            []
          else
            profile.id
            |> Statuses.list_public_for_profile(40)
            |> StatusJSON.render_many(viewer_id)
          end

        {:ok,
         socket
         |> assign(:page_title, "@#{account["acct"]}")
         |> assign(:profile, profile)
         |> assign(:account, account)
         |> assign(:remote?, not is_nil(profile.domain))
         |> assign(:posts, posts)}

      nil ->
        {:ok,
         socket
         |> assign(:page_title, "Not found")
         |> assign(:profile, nil)
         |> assign(:account, nil)
         |> assign(:posts, [])}
    end
  end

  @impl true
  def handle_event("favourite", %{"id" => id}, socket), do: react(socket, id, :favourite)
  def handle_event("reblog", %{"id" => id}, socket), do: react(socket, id, :reblog)

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

      <%= if @profile.is_private do %>
        <div class="text-center py-12 text-base-content/60">
          <.icon name="hero-lock-closed" class="size-6" />
          <p class="mt-2">This account is private.</p>
        </div>
      <% else %>
        <div class="space-y-3">
          <.post_card
            :for={post <- @posts}
            id={"post-#{post["id"]}"}
            status={post}
            current_user={@current_user}
          />
          <p :if={@posts == []} class="text-sm text-base-content/60 text-center py-8">
            No public posts yet.
          </p>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
