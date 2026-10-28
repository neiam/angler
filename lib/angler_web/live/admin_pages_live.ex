defmodule AnglerWeb.AdminPagesLive do
  @moduledoc """
  Admin editor for the `/site/*` pages (upstream `/i/admin/settings/pages`):
  pick a page, paste Markdown, preview it, save, or reset to the default.

  Gated by `AnglerWeb.LiveAuth` `:require_admin`.
  """
  use AnglerWeb, :live_view

  alias Angler.SitePages

  @impl true
  def mount(params, _session, socket) do
    key = if params["page"] in SitePages.keys(), do: params["page"], else: "terms"
    {:ok, socket |> assign(:page_title, "Site pages") |> select(key)}
  end

  defp select(socket, key) do
    page = SitePages.get(key)

    socket
    |> assign(:pages, SitePages.list())
    |> assign(:page, page)
    |> assign(:preview, SitePages.render(page.content))
    |> assign(:form, to_form(%{"title" => page.title, "content" => page.content}, as: :page))
  end

  @impl true
  def handle_event("select", %{"key" => key}, socket) when is_binary(key) do
    if key in SitePages.keys(), do: {:noreply, select(socket, key)}, else: {:noreply, socket}
  end

  def handle_event("preview", %{"page" => params}, socket) do
    {:noreply,
     socket
     |> assign(:preview, SitePages.render(params["content"] || ""))
     |> assign(:form, to_form(params, as: :page))}
  end

  def handle_event("save", %{"page" => params}, socket) do
    key = socket.assigns.page.key

    case SitePages.put(key, params) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Page saved.") |> select(key)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't save: the page is too long.")}
    end
  end

  def handle_event("reset", _params, socket) do
    key = socket.assigns.page.key
    :ok = SitePages.reset(key)
    {:noreply, socket |> put_flash(:info, "Page reset to the default.") |> select(key)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-5xl space-y-6">
        <div>
          <.link navigate={~p"/admin"} class="link text-sm">← Admin settings</.link>
          <h1 class="text-2xl font-bold">Site pages</h1>
          <p class="text-sm text-base-content/60">
            Markdown. The Pixelfed app links to the terms, privacy and help pages. Raw HTML
            is dropped when shown.
          </p>
        </div>

        <div class="grid gap-6 md:grid-cols-[14rem_1fr]">
          <nav id="site-pages" class="flex flex-col gap-1">
            <button
              :for={p <- @pages}
              type="button"
              id={"site-page-#{p.key}"}
              phx-click="select"
              phx-value-key={p.key}
              class={[
                "btn btn-sm justify-between transition-colors",
                if(p.key == @page.key, do: "btn-primary", else: "btn-ghost")
              ]}
            >
              <span class="truncate">{p.title}</span>
              <span :if={!p.custom?} class="badge badge-ghost badge-xs">default</span>
            </button>
          </nav>

          <div class="space-y-4">
            <div class="flex items-center justify-between gap-3 text-sm">
              <a href={@page.path} target="_blank" class="link font-mono">{@page.path}</a>
              <button
                :if={@page.custom?}
                id="reset-page"
                type="button"
                phx-click="reset"
                data-confirm="Discard this page and go back to the default?"
                class="btn btn-ghost btn-xs"
              >
                Reset to default
              </button>
            </div>

            <.form for={@form} id="page-form" phx-change="preview" phx-submit="save" class="space-y-3">
              <.input field={@form[:title]} label="Title" maxlength="120" />
              <.input
                field={@form[:content]}
                type="textarea"
                label="Content (Markdown)"
                rows="16"
                class="textarea textarea-bordered w-full font-mono text-sm"
                phx-debounce="300"
              />
              <button type="submit" class="btn btn-primary" phx-disable-with="Saving…">
                Save page
              </button>
            </.form>

            <section class="card bg-base-200 border border-base-300">
              <div class="card-body p-5">
                <h2 class="text-xs uppercase tracking-wide text-base-content/60">Preview</h2>
                <div id="page-preview" class="site-page">{Phoenix.HTML.raw(@preview)}</div>
              </div>
            </section>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
