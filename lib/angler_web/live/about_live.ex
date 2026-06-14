defmodule AnglerWeb.AboutLive do
  @moduledoc """
  Public "about this server" page — long description, server rules, the admin
  team, and contact info (à la pixelfed.social's about page).
  """
  use AnglerWeb, :live_view

  import AnglerWeb.PublicComponents, only: [avatar: 1, display_name: 1]

  alias Angler.Accounts
  alias Angler.Instance

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "About #{Instance.title()}")
     |> assign(:title, Instance.title())
     |> assign(:description, Instance.description())
     |> assign(:short_description, Instance.short_description())
     |> assign(:contact_email, Instance.contact_email())
     |> assign(:rules, Instance.rules())
     |> assign(:stats, Instance.stats())
     |> assign(:admins, Enum.map(Accounts.list_admins(), &admin_card/1))}
  end

  defp admin_card(profile) do
    %{
      username: profile.username,
      account: %{
        "username" => profile.username,
        "display_name" => profile.name || "",
        "avatar" => profile.avatar_path || ""
      }
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <article class="space-y-8">
        <header class="space-y-2">
          <h1 class="text-3xl font-bold tracking-tight">About {@title}</h1>
          <p class="text-base-content/70">{@short_description}</p>
        </header>

        <div class="grid grid-cols-3 gap-3">
          <.stat label="Users" value={@stats.user_count} />
          <.stat label="Posts" value={@stats.status_count} />
          <.stat label="Known servers" value={@stats.domain_count} />
        </div>

        <section :if={@description not in [nil, ""]} class="space-y-2">
          <h2 class="text-lg font-semibold">About</h2>
          <p class="prose prose-sm max-w-none whitespace-pre-line text-base-content/80">
            {@description}
          </p>
        </section>

        <section class="space-y-3">
          <h2 class="text-lg font-semibold">Administrators</h2>
          <div :if={@admins == []} class="text-sm text-base-content/60">
            No administrators are listed.
          </div>
          <ul class="grid gap-2 sm:grid-cols-2">
            <li :for={admin <- @admins}>
              <.link
                navigate={~p"/@#{admin.username}"}
                class="flex items-center gap-3 card bg-base-200 border border-base-300 p-3 hover:border-primary"
              >
                <.avatar account={admin.account} class="size-10" />
                <span class="min-w-0">
                  <span class="block font-medium truncate">{display_name(admin.account)}</span>
                  <span class="block text-xs text-base-content/60 truncate">@{admin.username}</span>
                </span>
              </.link>
            </li>
          </ul>
        </section>

        <section :if={@rules != []} class="space-y-2">
          <h2 class="text-lg font-semibold">Server rules</h2>
          <ol class="list-decimal pl-5 space-y-1 text-base-content/80">
            <li :for={rule <- @rules}>{rule}</li>
          </ol>
        </section>

        <section class="space-y-2">
          <h2 class="text-lg font-semibold">Contact</h2>
          <p :if={@contact_email} class="text-sm">
            <a href={"mailto:#{@contact_email}"} class="link link-primary">{@contact_email}</a>
          </p>
          <p :if={is_nil(@contact_email)} class="text-sm text-base-content/60">
            No contact email is configured.
          </p>
        </section>

        <section class="space-y-2">
          <h2 class="text-lg font-semibold">Powered by</h2>
          <p class="text-sm text-base-content/70">
            {@title} runs Angler, a Pixelfed-compatible server.
            <.link navigate={~p"/features"} class="link link-primary">See supported features →</.link>
          </p>
        </section>

        <footer class="py-10 sm:py-12 mt-8 border-t border-base-300 text-center">
          <p class="font-mono text-xs uppercase tracking-[0.25em] text-base-content/70 flex items-center justify-center gap-2">
            <span class="font-bold tracking-[0.16em]">ANGLER</span>
            <span class="opacity-50">·</span>
            <span>a</span>
            <%!--
              Hardcoded oklch from the neiam-co accent (the value every ported
              theme assigns to --color-accent). Inline so the NEIAM mark stays
              yellow regardless of which theme the viewer has picked.
            --%>
            <span class="font-bold tracking-[0.16em]" style="color: oklch(96% 0.058 96);">
              <a href="https://neiam.org">NEIAM</a>
            </span>
            <span>production</span>
          </p>
        </footer>
      </article>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp stat(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body items-center p-4">
        <div class="text-2xl font-bold tabular-nums">{@value}</div>
        <div class="text-xs uppercase tracking-wide text-base-content/60">{@label}</div>
      </div>
    </div>
    """
  end
end
