defmodule AnglerWeb.SitePageLive do
  @moduledoc """
  Public `/site/*` pages (terms, privacy, help, ...) and the app's `/e/terms`
  and `/e/privacy`, rendered from `Angler.SitePages`. The live action is the
  page key; `:index` (`/site` and `/site/kb`) is a landing that lists them all.
  """
  use AnglerWeb, :live_view

  alias Angler.SitePages
  alias AnglerWeb.MetaTags

  # One-line blurbs for the landing, by page key, in two groups.
  @groups [
    {"Policies",
     [
       {"terms", "The agreement for using this server."},
       {"privacy", "What we store about you, and what we share with other servers."},
       {"community-guidelines", "How we expect everyone here to behave."},
       {"legal-notice", "Who runs this server."}
     ]},
    {"Help",
     [
       {"help", "Getting started, apps, posting, and your data."},
       {"licenses", "What the license on a photo means."},
       {"instance-actor", "The account that represents this server itself."}
     ]}
  ]

  @impl true
  def mount(_params, _session, %{assigns: %{live_action: :index}} = socket) do
    pages = Map.new(SitePages.list(), &{&1.key, &1})

    groups =
      for {heading, entries} <- @groups do
        {heading, for({key, blurb} <- entries, do: Map.put(pages[key], :blurb, blurb))}
      end

    {:ok,
     socket
     |> assign(:page_title, "Policies & help")
     |> assign(:meta, MetaTags.page("Policies & help", nil, "/site"))
     |> assign(:groups, groups)}
  end

  def mount(_params, _session, socket) do
    page = SitePages.get(page_key(socket.assigns.live_action))

    {:ok,
     socket
     |> assign(:page_title, page.title)
     |> assign(:meta, MetaTags.page(page.title, SitePages.render(page.content), page.path))
     |> assign(:page, page)
     |> assign(:html, SitePages.render(page.content))}
  end

  defp page_key(action), do: action |> Atom.to_string() |> String.replace("_", "-")

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <section id="site-index" class="space-y-8">
        <h1 class="text-3xl font-bold tracking-tight">Policies &amp; help</h1>

        <div :for={{heading, pages} <- @groups} class="space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            {heading}
          </h2>
          <ul class="grid gap-2 sm:grid-cols-2">
            <li :for={p <- pages}>
              <.link
                id={"site-link-#{p.key}"}
                navigate={p.path}
                class="group flex h-full items-start gap-3 rounded-box border border-base-300 bg-base-200 p-4 transition hover:border-primary/50 hover:bg-base-300"
              >
                <div class="min-w-0 flex-1">
                  <div class="font-semibold group-hover:text-primary">{p.title}</div>
                  <p class="mt-1 text-sm text-base-content/70">{p.blurb}</p>
                </div>
                <.icon
                  name="hero-chevron-right-micro"
                  class="mt-0.5 size-4 shrink-0 text-base-content/40 transition group-hover:translate-x-0.5 group-hover:text-primary"
                />
              </.link>
            </li>
          </ul>
        </div>
      </section>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <article id="site-page" class="mx-auto max-w-2xl space-y-6">
        <.link
          id="site-index-link"
          navigate={~p"/site"}
          class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content"
        >
          <.icon name="hero-arrow-left-micro" class="size-4" /> Policies &amp; help
        </.link>
        <h1 class="text-3xl font-bold tracking-tight">{@page.title}</h1>
        <div id="site-page-body" class="site-page">{Phoenix.HTML.raw(@html)}</div>
      </article>
    </Layouts.app>
    """
  end
end
