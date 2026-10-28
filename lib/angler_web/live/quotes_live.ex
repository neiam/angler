defmodule AnglerWeb.QuotesLive do
  @moduledoc """
  Authenticated settings page listing the quote approvals (FEP-044f stamps)
  the current user has given remote posts, with a revoke control for each.
  Revoking tells the quoting server, which takes the quote down. Upstream's
  settings/privacy/quotes. Who may quote at all is set on the profile editor.
  """
  use AnglerWeb, :live_view

  alias Angler.Quotes

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_profile do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/login?next=/settings/quotes")}

      profile ->
        {:ok,
         socket
         |> assign(:page_title, "Quotes of your posts")
         |> load(profile)}
    end
  end

  @impl true
  def handle_event("revoke", %{"id" => id}, socket) do
    profile = socket.assigns.current_profile

    socket =
      with {id, ""} <- Integer.parse(id),
           :ok <- Quotes.revoke(profile.id, id) do
        put_flash(socket, :info, "Quote approval revoked.")
      else
        _ -> socket
      end

    {:noreply, load(socket, profile)}
  end

  defp load(socket, profile), do: assign(socket, :quotes, Quotes.list_approved(profile.id))

  defp handle(%{username: u, domain: d}), do: "@#{u}@#{d}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-xl space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">Quotes of your posts</h1>
          <span class="text-sm text-base-content/60">{length(@quotes)} approved</span>
        </div>

        <p class="text-sm text-base-content/70">
          Posts on other servers you've allowed to quote yours. Revoking asks
          their server to take the quote down.
          <.link navigate={~p"/settings/profile"} class="link">Who can quote you</.link>
          is set on your profile.
        </p>

        <ul :if={@quotes != []} id="quotes" class="space-y-2">
          <li
            :for={q <- @quotes}
            id={"quote-#{q.id}"}
            class="card bg-base-200 border border-base-300 transition-colors hover:border-base-content/20"
          >
            <div class="card-body flex-row items-center gap-3 p-3">
              <div class="min-w-0 flex-1 space-y-0.5">
                <a
                  href={q.quote_url}
                  rel="noopener nofollow"
                  target="_blank"
                  class="block truncate font-semibold hover:underline"
                >
                  {handle(q.actor)}
                </a>
                <.link
                  navigate={~p"/p/#{@current_profile.username}/#{q.status_id}"}
                  class="block truncate text-xs text-base-content/60 hover:underline"
                >
                  quoting your post from {Calendar.strftime(q.status.inserted_at, "%b %-d, %Y")}
                </.link>
              </div>
              <button
                type="button"
                id={"revoke-quote-#{q.id}"}
                class="btn btn-ghost btn-xs"
                phx-click="revoke"
                phx-value-id={q.id}
                data-confirm="Revoke this quote approval?"
              >
                Revoke
              </button>
            </div>
          </li>
        </ul>

        <div :if={@quotes == []} id="quotes-empty" class="alert text-sm">
          <.icon name="hero-chat-bubble-bottom-center-text" class="size-5 shrink-0" />
          <span>Nobody has quoted your posts yet.</span>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
