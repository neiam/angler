defmodule AnglerWeb.SitePageLive do
  @moduledoc """
  Public `/site/*` pages (terms, privacy, help, ...) and the app's `/e/terms`
  and `/e/privacy`, rendered from `Angler.SitePages`. The live action is the
  page key.
  """
  use AnglerWeb, :live_view

  alias Angler.SitePages

  @impl true
  def mount(_params, _session, socket) do
    page = SitePages.get(page_key(socket.assigns.live_action))

    {:ok,
     socket
     |> assign(:page_title, page.title)
     |> assign(:page, page)
     |> assign(:html, SitePages.render(page.content))}
  end

  defp page_key(action), do: action |> Atom.to_string() |> String.replace("_", "-")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <article id="site-page" class="mx-auto max-w-2xl space-y-6">
        <h1 class="text-3xl font-bold tracking-tight">{@page.title}</h1>
        <div id="site-page-body" class="site-page">{Phoenix.HTML.raw(@html)}</div>
      </article>
    </Layouts.app>
    """
  end
end
