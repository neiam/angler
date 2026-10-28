defmodule AnglerWeb.AboutLive do
  @moduledoc """
  Public "about this server" page — long description, server rules, the admin
  team, and contact info (à la pixelfed.social's about page).
  """
  use AnglerWeb, :live_view

  import AnglerWeb.PublicComponents, only: [avatar: 1, display_name: 1]

  alias Angler.Accounts
  alias Angler.Instance

  # {key, label, binary} — container runtimes for the "Run your own" matrix.
  @runtimes [{:docker, "Docker", "docker"}, {:podman, "Podman", "podman"}]

  # {key, label, image} — registries the `neiam/angler` image is published to.
  @registries [
    {:dockerhub, "Docker Hub", "docker.io/neiam/angler"},
    {:ghcr, "GitHub", "ghcr.io/neiam/angler"},
    {:quay, "Quay", "quay.io/neiam/angler"}
  ]

  # The /site/* pages worth linking here; the legal notice only once written.
  @linked_pages ~w(terms privacy community-guidelines help)

  defp site_pages do
    Enum.filter(Angler.SitePages.list(), fn p ->
      p.key in @linked_pages or (p.key == "legal-notice" and p.custom?)
    end)
  end

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
     |> assign(:site_pages, site_pages())
     |> assign(:stats, Instance.stats())
     |> assign(:admins, Enum.map(Accounts.list_admins(), &admin_card/1))
     |> assign(:runtimes, @runtimes)
     |> assign(:registries, @registries)
     |> assign(:runtime, :podman)
     |> assign(:registry, :ghcr)
     |> assign(:config_form, to_form(%{"user" => "", "pass" => "", "host" => ""}))
     |> recompute_commands()}
  end

  @impl true
  def handle_event("set_runtime", %{"runtime" => runtime}, socket) do
    {:noreply,
     socket |> assign(:runtime, String.to_existing_atom(runtime)) |> recompute_commands()}
  end

  def handle_event("set_registry", %{"registry" => registry}, socket) do
    {:noreply,
     socket |> assign(:registry, String.to_existing_atom(registry)) |> recompute_commands()}
  end

  def handle_event("set_config", params, socket) do
    form = to_form(Map.take(params, ["user", "pass", "host"]))
    {:noreply, socket |> assign(:config_form, form) |> recompute_commands()}
  end

  # Rebuild both command strings from the current runtime/registry + the
  # (possibly blank) values typed into the ghost config inputs.
  defp recompute_commands(socket) do
    %{runtime: runtime, registry: registry, config_form: form} = socket.assigns
    user = field(form, :user, "USER")
    pass = field(form, :pass, "PASS")
    host = field(form, :host, "angler.you.com")

    socket
    |> assign(:run_command, build_command(runtime, registry, user, pass, host))
    |> assign(:db_command, build_db_command(runtime, user, pass))
  end

  defp build_db_command(runtime, user, pass) do
    bin = lookup(@runtimes, runtime)

    Enum.join(
      [
        "#{bin} run -d --name angler-db",
        "-p 5432:5432",
        "-e POSTGRES_USER=#{user}",
        "-e POSTGRES_PASSWORD=#{pass}",
        "-e POSTGRES_DB=angler",
        "-v angler-db:/var/lib/postgresql/data",
        "docker.io/postgres:16-alpine"
      ],
      " \\\n  "
    )
  end

  defp build_command(runtime, registry, user, pass, host) do
    bin = lookup(@runtimes, runtime)
    image = lookup(@registries, registry)

    Enum.join(
      [
        "#{bin} run -d --name angler",
        "-p 4000:4000",
        "-e PHX_HOST=#{host}",
        "-e SECRET_KEY_BASE=$(openssl rand -base64 48)",
        "-e DATABASE_URL=ecto://#{user}:#{pass}@HOST/angler",
        "#{image}:latest"
      ],
      " \\\n  "
    )
  end

  # The trimmed field value, or the placeholder default when left blank.
  defp field(form, key, default) do
    case form[key].value |> to_string() |> String.trim() do
      "" -> default
      value -> value
    end
  end

  defp lookup(rows, key) do
    {_key, _label, value} = Enum.find(rows, fn {k, _, _} -> k == key end)
    value
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

        <section id="about-policies" class="space-y-2">
          <h2 class="text-lg font-semibold">Policies &amp; help</h2>
          <ul class="flex flex-wrap gap-2">
            <li :for={p <- @site_pages}>
              <.link
                navigate={p.path}
                id={"about-page-#{p.key}"}
                class="btn btn-sm btn-ghost border border-base-300 transition-colors hover:border-base-content/30"
              >
                {p.title}
              </.link>
            </li>
          </ul>
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

        <section class="space-y-3">
          <h2 class="text-lg font-semibold">Run your own</h2>
          <p class="text-sm text-base-content/70">
            <span class="font-medium text-base-content">Get started in 30 seconds.</span>
            Angler is easy to run because it ships as a single container image. Pick your runtime
            and registry, then run:
          </p>

          <div class="flex flex-wrap items-center gap-2">
            <div role="tablist" class="tabs tabs-boxed bg-base-200" aria-label="Container runtime">
              <button
                :for={{key, label, _bin} <- @runtimes}
                type="button"
                role="tab"
                phx-click="set_runtime"
                phx-value-runtime={key}
                class={["tab", @runtime == key && "tab-active font-semibold"]}
              >
                {label}
              </button>
            </div>
            <div role="tablist" class="tabs tabs-boxed bg-base-200" aria-label="Registry">
              <button
                :for={{key, label, _image} <- @registries}
                type="button"
                role="tab"
                phx-click="set_registry"
                phx-value-registry={key}
                class={["tab", @registry == key && "tab-active font-semibold"]}
              >
                {label}
              </button>
            </div>
          </div>

          <.form
            for={@config_form}
            id="run-config"
            phx-change="set_config"
            class="flex flex-wrap items-center gap-x-4 gap-y-1 font-mono text-sm"
          >
            <label class="flex items-center gap-1.5">
              <span class="text-base-content/40">user</span>
              <input
                type="text"
                name="user"
                value={@config_form[:user].value}
                placeholder="USER"
                autocomplete="off"
                spellcheck="false"
                phx-debounce="150"
                aria-label="Database user"
                class="input input-ghost input-xs w-24 px-1"
              />
            </label>
            <label class="flex items-center gap-1.5">
              <span class="text-base-content/40">password</span>
              <input
                type="text"
                name="pass"
                value={@config_form[:pass].value}
                placeholder="PASS"
                autocomplete="off"
                spellcheck="false"
                phx-debounce="150"
                aria-label="Database password"
                class="input input-ghost input-xs w-24 px-1"
              />
            </label>
            <label class="flex items-center gap-1.5">
              <span class="text-base-content/40">host</span>
              <input
                type="text"
                name="host"
                value={@config_form[:host].value}
                placeholder="angler.you.com"
                autocomplete="off"
                spellcheck="false"
                phx-debounce="150"
                aria-label="Public host"
                class="input input-ghost input-xs w-40 px-1"
              />
            </label>
          </.form>

          <div class="collapse collapse-arrow rounded-box border border-base-300 bg-base-200">
            <input type="checkbox" aria-label="Toggle database setup" />
            <div class="collapse-title text-sm font-medium">Start your database</div>
            <div class="collapse-content space-y-2">
              <p class="text-xs text-base-content/60">
                Angler needs PostgreSQL. Start one and point <code>DATABASE_URL</code> at it:
              </p>
              <div class="relative">
                <button
                  type="button"
                  id="copy-db-command"
                  phx-hook=".CopyCommand"
                  data-target="db-command"
                  class="btn btn-ghost btn-xs absolute right-2 top-2 gap-1"
                  aria-label="Copy database command"
                >
                  <.icon name="hero-clipboard-document-micro" class="size-4" />
                  <span data-label>Copy</span>
                </button>
                <pre
                  id="db-command"
                  class="overflow-x-auto rounded-box bg-base-300 p-4 pt-9 text-xs leading-relaxed sm:text-sm"
                ><code>{@db_command}</code></pre>
              </div>
            </div>
          </div>

          <div class="relative">
            <button
              type="button"
              id="copy-run-command"
              phx-hook=".CopyCommand"
              data-target="run-command"
              class="btn btn-ghost btn-xs absolute right-2 top-2 gap-1"
              aria-label="Copy command"
            >
              <.icon name="hero-clipboard-document-micro" class="size-4" />
              <span data-label>Copy</span>
            </button>
            <pre
              id="run-command"
              class="overflow-x-auto rounded-box bg-base-300 p-4 pt-9 text-xs leading-relaxed sm:text-sm"
            ><code>{@run_command}</code></pre>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyCommand">
              export default {
                mounted() {
                  this.el.addEventListener("click", () => {
                    const pre = document.getElementById(this.el.dataset.target)
                    if (!pre || !navigator.clipboard) return
                    navigator.clipboard.writeText(pre.textContent.trim()).then(() => {
                      const label = this.el.querySelector("[data-label]")
                      if (!label) return
                      const prev = label.textContent
                      label.textContent = "Copied!"
                      setTimeout(() => { label.textContent = prev }, 1500)
                    }).catch(() => {})
                  })
                }
              }
            </script>
          </div>

          <p class="text-xs text-base-content/50">
            Replace the database URL, host, and generated secret with your own. The server listens
            on port 4000; run migrations once with <code class="text-base-content/70">{@runtime} exec angler bin/migrate</code>.
          </p>
          <p class="text-xs text-base-content/50">
            More complex setups (Compose, Kubernetes) can be found in the repo documentation.
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
