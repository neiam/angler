defmodule AnglerWeb.ProfileFollowsLive do
  @moduledoc """
  Follower / following lists for a local account at `/@:username/followers`
  and `/@:username/following`. The `live_action` (`:followers` | `:following`)
  selects which edge to list. Private accounts show a locked notice and no
  list, mirroring `AnglerWeb.ProfileLive`.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.PublicComponents, only: [account_row: 1]

  alias Angler.Follows
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias AnglerWeb.MastodonAPI.Account

  @limit 80

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    action = socket.assigns.live_action

    case Profiles.get_local_by_username(username) do
      %Profile{} = profile ->
        accounts =
          if profile.is_private,
            do: [],
            else: profile |> list(action) |> Enum.map(&Account.render/1)

        {:ok,
         socket
         |> assign(:page_title, "@#{profile.username} · #{heading(action)}")
         |> assign(:profile, profile)
         |> assign(:action, action)
         |> assign(:accounts, accounts)}

      nil ->
        {:ok,
         socket
         |> assign(:page_title, "Not found")
         |> assign(:profile, nil)
         |> assign(:action, action)
         |> assign(:accounts, [])}
    end
  end

  defp list(profile, :followers), do: Follows.list_followers(profile, limit: @limit)
  defp list(profile, :following), do: Follows.list_following(profile, limit: @limit)

  defp heading(:followers), do: "Followers"
  defp heading(:following), do: "Following"

  defp empty_label(:followers), do: "No followers yet."
  defp empty_label(:following), do: "Not following anyone yet."

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
      <header class="space-y-3">
        <.link
          navigate={~p"/@#{@profile.username}"}
          class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content"
        >
          <.icon name="hero-arrow-left-micro" class="size-4" /> @{@profile.username}
        </.link>

        <div role="tablist" class="tabs tabs-bordered">
          <.link
            role="tab"
            navigate={~p"/@#{@profile.username}/followers"}
            class={["tab", @action == :followers && "tab-active font-semibold"]}
          >
            Followers
          </.link>
          <.link
            role="tab"
            navigate={~p"/@#{@profile.username}/following"}
            class={["tab", @action == :following && "tab-active font-semibold"]}
          >
            Following
          </.link>
        </div>
      </header>

      <%= if @profile.is_private do %>
        <div class="text-center py-12 text-base-content/60">
          <.icon name="hero-lock-closed" class="size-6" />
          <p class="mt-2">This account is private.</p>
        </div>
      <% else %>
        <div class="space-y-2">
          <.account_row :for={account <- @accounts} account={account} />
          <p :if={@accounts == []} class="text-sm text-base-content/60 text-center py-8">
            {empty_label(@action)}
          </p>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
