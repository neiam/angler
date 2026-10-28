defmodule AnglerWeb.FeaturedCollectionsLive do
  @moduledoc """
  Authenticated settings page listing the remote featured collections
  (FEP-7aa9 stamps) the current user has been added to, with a control to
  leave each. Leaving tells the collection's server, which drops you from
  it. Upstream's settings/privacy/featured-collections. Who may feature you
  at all is set on the profile editor.
  """
  use AnglerWeb, :live_view

  alias Angler.FeaturedCollections

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_profile do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/login?next=/settings/featured")}

      profile ->
        {:ok,
         socket
         |> assign(:page_title, "Featured collections")
         |> load(profile)}
    end
  end

  @impl true
  def handle_event("remove", %{"id" => id}, socket) do
    profile = socket.assigns.current_profile

    socket =
      with {id, ""} <- Integer.parse(id),
           :ok <- FeaturedCollections.revoke(profile.id, id) do
        put_flash(socket, :info, "You have been removed from the collection.")
      else
        _ -> socket
      end

    {:noreply, load(socket, profile)}
  end

  defp load(socket, profile),
    do: assign(socket, :collections, FeaturedCollections.list_approved(profile.id))

  defp handle(%{username: u, domain: d}), do: "@#{u}@#{d}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-xl space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">Featured collections</h1>
          <span class="text-sm text-base-content/60">{length(@collections)} collections</span>
        </div>

        <p class="text-sm text-base-content/70">
          Collections on other servers that feature your account. Removing
          yourself asks their server to take you out of the collection.
          <.link navigate={~p"/settings/profile"} class="link">Who can feature you</.link>
          is set on your profile.
        </p>

        <ul :if={@collections != []} id="featured-collections" class="space-y-2">
          <li
            :for={c <- @collections}
            id={"featured-#{c.id}"}
            class="card bg-base-200 border border-base-300 transition-colors hover:border-base-content/20"
          >
            <div class="card-body flex-row items-center gap-3 p-3">
              <div class="min-w-0 flex-1 space-y-0.5">
                <a
                  href={c.collection_url}
                  rel="noopener nofollow"
                  target="_blank"
                  class="block truncate font-semibold hover:underline"
                >
                  {c.collection_name || "Untitled collection"}
                </a>
                <span class="block truncate text-xs text-base-content/60">
                  by {handle(c.actor)} · since {Calendar.strftime(c.inserted_at, "%b %-d, %Y")}
                </span>
              </div>
              <button
                type="button"
                id={"remove-featured-#{c.id}"}
                class="btn btn-ghost btn-xs"
                phx-click="remove"
                phx-value-id={c.id}
                data-confirm="Remove yourself from this collection?"
              >
                Remove
              </button>
            </div>
          </li>
        </ul>

        <div :if={@collections == []} id="featured-collections-empty" class="alert text-sm">
          <.icon name="hero-rectangle-stack" class="size-5 shrink-0" />
          <span>No collections feature you yet.</span>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
