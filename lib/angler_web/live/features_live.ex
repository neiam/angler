defmodule AnglerWeb.FeaturesLive do
  @moduledoc """
  Public "supported features" page — a curated overview of what this
  Pixelfed-compatible server implements.
  """
  use AnglerWeb, :live_view

  alias Angler.Instance

  # What changed in Angler 0.2 (the Pixelfed 0.15 series), newest first.
  @whats_new [
    "Group chats and message requests in DMs, with mute, hide and leave",
    "Boosts in your home feed and on profiles (Pixelfed app: Settings → Timelines)",
    "Quote posts: choose who may quote you, per post or for your account",
    "Choose who may feature you in their collections",
    "Stories federate both ways, with replies and reactions arriving as DMs",
    "Follower lists and blocks stay in sync with other servers",
    "Curated sign-ups, captcha and spam protection for registration",
    "Editable terms, privacy and help pages"
  ]

  @sections [
    {"Photo sharing", "hero-photo",
     [
       "Single photos and multi-photo albums",
       "Captions, content warnings, alt text and media licenses",
       "Per-post visibility: public, unlisted, followers-only, direct",
       "Quote posts with consent: per-post and account-wide quote policies"
     ]},
    {"Timelines & discovery", "hero-rectangle-stack",
     [
       "Home, local, and federated (\"known network\") timelines",
       "Boosts in timelines, with a photos-only option",
       "Trending posts and hashtags, plus Pixelfed's network-wide trending feed",
       "Discover, directory, and full-text search"
     ]},
    {"Social", "hero-users",
     [
       "Follows, follow requests, blocks, mutes, and lists",
       "Likes, boosts, bookmarks, replies, and threaded comments",
       "Featured collections, with consent from the people featured"
     ]},
    {"Direct messages", "hero-chat-bubble-left-right",
     [
       "One-to-one and group conversations (up to 10 people)",
       "Message requests from people you don't follow",
       "Unread counts, mute, hide, and leave",
       "Notifications that open the right conversation"
     ]},
    {"Stories", "hero-bolt",
     [
       "Ephemeral stories with drafts and cross-posting",
       "Viewers, replies, and reactions",
       "Federated with other Pixelfed servers, both ways"
     ]},
    {"Groups", "hero-user-group",
     [
       "Public, private, and secret groups",
       "Members, invites, reports, and threaded group posts"
     ]},
    {"Federation", "hero-globe-alt",
     [
       "ActivityPub with signed delivery, and backoff for servers that are down",
       "Follower lists and blocks kept in sync across servers (FEP-8fcf, FEP-070c)",
       "Consent-respecting quotes and featuring (FEP-044f)",
       "Interoperates with Pixelfed, Mastodon, and the wider fediverse"
     ]},
    {"Safety & moderation", "hero-shield-check",
     [
       "Reports for posts, profiles, stories, and messages",
       "Captcha (hCaptcha, Turnstile, or Cap) and a honeypot on sign-up",
       "Curated registration: applicants are approved by an admin",
       "Per-account storage limits and rate-limited logins"
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
     |> assign(:sections, @sections)
     |> assign(:whats_new, @whats_new)
     |> assign(:version, Angler.Federation.Nodeinfo.version())
     |> assign(:pixelfed, Angler.Federation.Nodeinfo.pixelfed_compat())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="space-y-6">
        <header class="space-y-2">
          <h1 class="text-3xl font-bold tracking-tight">Features</h1>
          <p class="text-base-content/70">
            What {@title} can do. Angler {@version}, compatible with Pixelfed {@pixelfed}.
          </p>
        </header>

        <section id="whats-new" class="card bg-primary/5 border border-primary/30">
          <div class="card-body gap-3 p-5">
            <h2 class="flex items-center gap-2 text-lg font-semibold">
              <.icon name="hero-sparkles" class="size-5 text-primary" /> New in Angler 0.2
            </h2>
            <ul class="grid gap-x-6 gap-y-1.5 text-sm text-base-content/80 sm:grid-cols-2">
              <li :for={item <- @whats_new} class="flex gap-2">
                <.icon name="hero-plus-micro" class="size-4 text-primary shrink-0 mt-0.5" />
                <span>{item}</span>
              </li>
            </ul>
          </div>
        </section>

        <div class="grid gap-4 sm:grid-cols-2">
          <section
            :for={{title, icon, items} <- @sections}
            class="card bg-base-200 border border-base-300 transition-colors hover:border-base-content/20"
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
