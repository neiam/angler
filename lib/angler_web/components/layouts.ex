defmodule AnglerWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AnglerWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_user, :map, default: nil, doc: "the logged-in user, or nil"

  attr :current_profile, :map,
    default: nil,
    doc: "the logged-in user's local profile, or nil"

  attr :wide, :boolean,
    default: false,
    doc: "when true the inner block fills the viewport width with no max-width container"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8 border-b border-base-300 bg-base-200">
      <div class="navbar-start">
        <.link navigate={~p"/"} class="flex w-fit items-center gap-2">
          <span class="font-mono font-bold tracking-[0.16em] text-accent">ANGLER</span>
        </.link>
      </div>
      <div class="navbar-center">
        <.search_box />
      </div>
      <div class="navbar-end">
        <ul class="flex flex-row items-center gap-1">
          <li>
            <.theme_toggle />
          </li>
          <%= if @current_user do %>
            <li><span class="divider divider-horizontal mx-0" /></li>
            <li>
              <details class="dropdown dropdown-end">
                <summary class="btn btn-ghost btn-sm">
                  <.icon name="hero-user-circle-micro" class="size-4" />
                  <span class="hidden sm:inline truncate max-w-[12ch]">
                    {user_label(@current_user, @current_profile)}
                  </span>
                </summary>
                <ul class="dropdown-content menu bg-base-200 border border-base-300 rounded-box z-10 mt-1 w-52 p-1 shadow-lg">
                  <li :if={@current_profile} class="menu-title font-mono text-xs truncate">
                    @{@current_profile.username}
                  </li>
                  <li :if={@current_profile}>
                    <.link navigate={~p"/@#{@current_profile.username}"}>
                      <.icon name="hero-user-micro" class="size-4" /> My profile
                    </.link>
                  </li>
                  <li>
                    <.link navigate={~p"/settings/profile"}>
                      <.icon name="hero-pencil-square-micro" class="size-4" /> Edit profile
                    </.link>
                  </li>
                  <li>
                    <.link navigate={~p"/settings/followed-tags"}>
                      <.icon name="hero-hashtag-micro" class="size-4" /> Followed hashtags
                    </.link>
                  </li>
                  <li>
                    <.link navigate={~p"/settings/import/instagram"}>
                      <.icon name="hero-arrow-down-tray-micro" class="size-4" /> Import from Instagram
                    </.link>
                  </li>
                  <li :if={@current_user.is_admin}>
                    <.link navigate={~p"/admin"}>
                      <.icon name="hero-cog-6-tooth-micro" class="size-4" /> Admin settings
                    </.link>
                  </li>
                  <li :if={@current_user.is_admin}>
                    <.link navigate={~p"/admin/relays"}>
                      <.icon name="hero-signal-micro" class="size-4" /> Relays
                    </.link>
                  </li>
                  <li :if={@current_user.is_admin}>
                    <.link navigate={~p"/admin/curated-onboarding"}>
                      <.icon name="hero-user-plus-micro" class="size-4" /> Curated onboarding
                    </.link>
                  </li>
                  <li>
                    <.link href={~p"/session/logout"} method="post">
                      <.icon name="hero-arrow-right-on-rectangle-micro" class="size-4" /> Log out
                    </.link>
                  </li>
                </ul>
              </details>
            </li>
          <% else %>
            <li>
              <.link navigate={~p"/login"} class="btn btn-ghost btn-sm">Log in</.link>
            </li>
            <li>
              <.link navigate={~p"/register"} class="btn btn-primary btn-sm">Register</.link>
            </li>
          <% end %>
        </ul>
      </div>
    </header>

    <%= if @wide do %>
      <main class="w-full">
        {render_slot(@inner_block)}
      </main>
    <% else %>
      <main class="px-4 py-10 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-2xl space-y-4">
          {render_slot(@inner_block)}
        </div>
      </main>
    <% end %>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Global navbar search box. Not a `<form>` (so it never collides with a page's
  own form) — the colocated `.SearchBox` hook drives everything: a debounced
  type-ahead dropdown fetched from `/search/suggest`, Enter to jump to the full
  `/search` results page, and Escape/outside-click to dismiss.
  """
  def search_box(assigns) do
    ~H"""
    <div
      id="navbar-search"
      role="search"
      class="relative hidden sm:block"
      phx-hook=".SearchBox"
      phx-update="ignore"
    >
      <label class="input input-sm input-bordered flex items-center gap-2 w-44 lg:w-64">
        <.icon name="hero-magnifying-glass-micro" class="size-4 opacity-60" />
        <input
          type="search"
          placeholder="Search"
          autocomplete="off"
          aria-label="Search"
          data-search-input
          class="grow"
        />
      </label>
      <ul
        data-search-results
        class="hidden absolute left-0 right-0 z-20 mt-1 menu bg-base-200 border border-base-300 rounded-box p-1 shadow-lg max-h-96 flex-nowrap overflow-auto"
      >
      </ul>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".SearchBox">
        export default {
          mounted() {
            const root = this.el
            const input = root.querySelector("[data-search-input]")
            const box = root.querySelector("[data-search-results]")
            let timer

            const hide = () => { box.classList.add("hidden"); box.innerHTML = "" }
            const go = (q) => { if (q) window.location.assign(`/search?q=${encodeURIComponent(q)}`) }

            const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => (
              {"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}[c]
            ))

            const render = (data, q) => {
              const rows = []
              ;(data.accounts || []).forEach((a) => {
                rows.push(
                  `<li><a href="${esc(a.url)}" class="flex items-center gap-2">` +
                  `<span class="font-semibold truncate">${esc(a.display_name)}</span>` +
                  `<span class="opacity-60 text-xs truncate">@${esc(a.acct)}</span></a></li>`
                )
              })
              ;(data.hashtags || []).forEach((h) => {
                rows.push(
                  `<li><a href="${esc(h.url)}" class="flex items-center gap-2">` +
                  `<span>#${esc(h.name)}</span>` +
                  `<span class="opacity-60 text-xs ml-auto tabular-nums">${esc(h.count)}</span></a></li>`
                )
              })
              rows.push(
                `<li><a href="/search?q=${encodeURIComponent(q)}" class="text-primary">` +
                `See all results for &quot;${esc(q)}&quot;</a></li>`
              )
              box.innerHTML = rows.join("")
              box.classList.remove("hidden")
            }

            input.addEventListener("input", () => {
              clearTimeout(timer)
              const q = input.value.trim()
              if (q.length < 1) { hide(); return }
              timer = setTimeout(() => {
                fetch(`/search/suggest?q=${encodeURIComponent(q)}`, {headers: {accept: "application/json"}})
                  .then((r) => (r.ok ? r.json() : null))
                  .then((data) => { if (data) render(data, q) })
                  .catch(() => {})
              }, 200)
            })

            input.addEventListener("keydown", (e) => {
              if (e.key === "Enter") { e.preventDefault(); go(input.value.trim()) }
              else if (e.key === "Escape") { hide() }
            })
            document.addEventListener("click", (e) => { if (!root.contains(e.target)) hide() })
          }
        }
      </script>
    </div>
    """
  end

  defp user_label(_user, %{name: name}) when is_binary(name) and name != "", do: name
  defp user_label(_user, %{username: username}) when is_binary(username), do: username

  defp user_label(%{email: email}, _profile) when is_binary(email),
    do: hd(String.split(email, "@"))

  defp user_label(_user, _profile), do: "Account"

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Theme picker dropdown listing every theme defined in `app.css`, including
  the 6 ported neiam-co themes. The selected theme is persisted to
  localStorage by the script in `root.html.heex`, which also handles the
  `phx:set-theme` event dispatched here.
  """
  def theme_toggle(assigns) do
    assigns = assign_new(assigns, :themes, fn -> Angler.Themes.all() end)

    ~H"""
    <div class="dropdown dropdown-end">
      <div tabindex="0" role="button" class="btn btn-ghost btn-sm gap-2" aria-label="Choose theme">
        <.icon name="hero-swatch-micro" class="size-4" />
        <span class="hidden sm:inline">Theme</span>
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-200 border border-base-300 rounded-box z-10 mt-1 w-44 p-1 shadow-lg"
      >
        <li>
          <button
            type="button"
            phx-click={JS.dispatch("phx:set-theme")}
            data-phx-theme="system"
            class="flex items-center gap-2"
          >
            <.icon name="hero-computer-desktop-micro" class="size-4" /> System
          </button>
        </li>
        <li :for={theme <- @themes}>
          <button
            type="button"
            phx-click={JS.dispatch("phx:set-theme")}
            data-phx-theme={theme}
            class="flex items-center justify-between"
          >
            <span class="capitalize">{theme}</span>
            <span
              class="size-3 rounded-full border border-base-content/20"
              data-theme={theme}
              style="background: var(--color-primary)"
            />
          </button>
        </li>
      </ul>
    </div>
    """
  end
end
