defmodule AnglerWeb.FollowedTagsLive do
  @moduledoc """
  Authenticated settings page listing the hashtags the current user follows,
  with an unfollow control for each.

  Posts carrying a followed hashtag are fanned into the user's home timeline by
  `Angler.Timelines.Workers.FeedInsert`. This is the web counterpart to the
  Mastodon `/api/v1/followed_tags` screen the mobile app uses.
  """
  use AnglerWeb, :live_view

  alias Angler.Hashtags
  alias Angler.Hashtags.Following

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_profile do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/login?next=/settings/followed-tags")}

      profile ->
        {:ok,
         socket
         |> assign(:page_title, "Followed hashtags")
         |> load_tags(profile)}
    end
  end

  @impl true
  def handle_event("unfollow", %{"name" => name}, socket) do
    profile = socket.assigns.current_profile
    :ok = Following.unfollow(profile, name)
    {:noreply, load_tags(socket, profile)}
  end

  defp load_tags(socket, profile) do
    rows =
      profile.id
      |> Following.list()
      |> Enum.map(&%{name: &1.name, count: Hashtags.usage_count(&1.name)})

    assign(socket, :tags, rows)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-xl space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">Followed hashtags</h1>
          <span class="text-sm text-base-content/60">{length(@tags)} followed</span>
        </div>

        <p class="text-sm text-base-content/70">
          Posts tagged with these hashtags show up in your home timeline.
        </p>

        <ul :if={@tags != []} class="space-y-2">
          <li :for={tag <- @tags} class="card bg-base-200 border border-base-300">
            <div class="card-body flex-row items-center gap-3 p-3">
              <.link
                navigate={~p"/tags/#{tag.name}"}
                class="min-w-0 flex-1 font-semibold hover:underline"
              >
                #{tag.name}
              </.link>
              <span class="text-xs text-base-content/60 whitespace-nowrap tabular-nums">
                {tag.count} posts
              </span>
              <button
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="unfollow"
                phx-value-name={tag.name}
              >
                Unfollow
              </button>
            </div>
          </li>
        </ul>

        <div :if={@tags == []} class="alert text-sm">
          <.icon name="hero-hashtag" class="size-5 shrink-0" />
          <span>
            You aren't following any hashtags yet. Open a
            <.link navigate={~p"/search"} class="link">hashtag</.link>
            and tap Follow.
          </span>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
