defmodule AnglerWeb.ProfileLive do
  @moduledoc """
  Public profile page at `/@:username` — a local account's header plus its
  latest public posts. Anonymous-safe: private accounts show a locked notice
  and no posts.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.PublicComponents

  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Statuses
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    case Profiles.get_local_by_username(username) do
      %Profile{} = profile ->
        posts =
          if profile.is_private do
            []
          else
            profile.id |> Statuses.list_public_for_profile(40) |> StatusJSON.render_many(nil)
          end

        {:ok,
         socket
         |> assign(:page_title, "@#{profile.username}")
         |> assign(:profile, profile)
         |> assign(:account, account_map(profile))
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

  defp account_map(%Profile{} = p) do
    %{
      "username" => p.username,
      "acct" => p.username,
      "display_name" => p.name || "",
      "avatar" => p.avatar_path || ""
    }
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
          <div class="text-base-content/60">@{@profile.username}</div>
          <div :if={@profile.bio not in [nil, ""]} class="mt-2 prose prose-sm max-w-none break-words">
            {raw(@profile.bio)}
          </div>
          <div class="mt-3 flex gap-4 text-sm text-base-content/70">
            <span>
              <span class="font-semibold text-base-content">{@profile.statuses_count}</span> posts
            </span>
            <span>
              <span class="font-semibold text-base-content">{@profile.followers_count}</span>
              followers
            </span>
            <span>
              <span class="font-semibold text-base-content">{@profile.following_count}</span>
              following
            </span>
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
          <.post_card :for={post <- @posts} id={"post-#{post["id"]}"} status={post} />
          <p :if={@posts == []} class="text-sm text-base-content/60 text-center py-8">
            No public posts yet.
          </p>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
