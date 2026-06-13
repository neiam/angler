defmodule AnglerWeb.FeaturesLive do
  @moduledoc """
  Public "supported features" page — a curated overview of what this
  Pixelfed-compatible server implements.
  """
  use AnglerWeb, :live_view

  alias Angler.Instance

  @sections [
    {"Photo sharing", "hero-photo",
     [
       "Single photos and multi-photo albums",
       "Captions, content warnings, and alt-text descriptions",
       "Per-post visibility: public, unlisted, followers-only, direct"
     ]},
    {"Timelines & discovery", "hero-rectangle-stack",
     [
       "Home, local, and federated (\"known network\") timelines",
       "Trending posts and hashtags",
       "Discover, directory, and full-text search"
     ]},
    {"Social", "hero-users",
     [
       "Follows, follow requests, blocks, mutes, and lists",
       "Likes, boosts, bookmarks, replies, and threaded comments",
       "Notifications and direct conversations"
     ]},
    {"Stories", "hero-bolt",
     [
       "Ephemeral stories with drafts and cross-posting",
       "Story viewers, replies, and federated story objects"
     ]},
    {"Groups", "hero-user-group",
     [
       "Public, private, and secret groups",
       "Members, invites, reports, and threaded group posts"
     ]},
    {"Federation", "hero-globe-alt",
     [
       "ActivityPub inbox/outbox with signed delivery",
       "Interoperates with Pixelfed, Mastodon, and the wider fediverse"
     ]},
    {"Apps & API", "hero-device-phone-mobile",
     [
       "Wire-compatible with the Pixelfed mobile app",
       "Mastodon-compatible /api/v1 + Pixelfed extensions",
       "OAuth, Web Push (VAPID), and Expo (FCM/APNs) notifications"
     ]}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Features")
     |> assign(:title, Instance.title())
     |> assign(:sections, @sections)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="space-y-6">
        <header class="space-y-2">
          <h1 class="text-3xl font-bold tracking-tight">Features</h1>
          <p class="text-base-content/70">What {@title} can do.</p>
        </header>

        <div class="grid gap-4 sm:grid-cols-2">
          <section
            :for={{title, icon, items} <- @sections}
            class="card bg-base-200 border border-base-300"
          >
            <div class="card-body gap-3 p-4">
              <h2 class="flex items-center gap-2 text-lg font-semibold">
                <.icon name={icon} class="size-5 text-primary" /> {title}
              </h2>
              <ul class="space-y-1 text-sm text-base-content/80">
                <li :for={item <- items} class="flex gap-2">
                  <.icon name="hero-check-micro" class="size-4 text-success shrink-0 mt-0.5" />
                  <span>{item}</span>
                </li>
              </ul>
            </div>
          </section>
        </div>

        <p class="text-center text-sm">
          <.link navigate={~p"/about"} class="link link-hover">← About this server</.link>
        </p>
      </div>
    </Layouts.app>
    """
  end
end
