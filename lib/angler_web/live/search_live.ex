defmodule AnglerWeb.SearchLive do
  @moduledoc """
  Full search results page at `/search?q=&type=`.

  The URL is the single source of truth: the input pushes a patch with the new
  query, `handle_params/3` runs the search via `Angler.Search`, and the `type`
  param selects the active tab (all / people / tags / posts). Results are
  viewer-scoped through `current_profile`, so a logged-in user also sees their
  own non-public matching posts.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.PublicComponents

  alias Angler.Hashtags
  alias Angler.Search
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON

  @tabs [{:all, "All"}, {:accounts, "People"}, {:hashtags, "Tags"}, {:statuses, "Posts"}]
  @limit 20

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Search")
     |> assign(:tabs, @tabs)
     |> assign(:query, "")
     |> assign(:tab, :all)
     |> assign(:searched?, false)
     |> assign(:accounts, [])
     |> assign(:hashtags, [])
     |> assign(:statuses, [])
     |> assign(:form, to_form(%{"q" => ""}))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    q = String.trim(params["q"] || "")
    tab = parse_tab(params["type"])

    socket =
      socket
      |> assign(:query, q)
      |> assign(:tab, tab)
      |> assign(:form, to_form(%{"q" => q}))

    {:noreply, run_search(socket, q)}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: ~p"/search?#{%{q: q, type: socket.assigns.tab}}")}
  end

  def handle_event("favourite", %{"id" => id}, socket), do: react(socket, id, :favourite)
  def handle_event("reblog", %{"id" => id}, socket), do: react(socket, id, :reblog)

  defp react(socket, id, kind) do
    case AnglerWeb.Live.Interactions.toggle(socket.assigns.current_profile, id, kind) do
      {:ok, rendered} ->
        statuses =
          Enum.map(socket.assigns.statuses, fn s ->
            if s["id"] == rendered["id"], do: rendered, else: s
          end)

        {:noreply, assign(socket, :statuses, statuses)}

      :error ->
        {:noreply, socket}
    end
  end

  ## Internals

  # Re-run only when there's a query; otherwise reset to an empty landing state.
  defp run_search(socket, "") do
    socket
    |> assign(:searched?, false)
    |> assign(:accounts, [])
    |> assign(:hashtags, [])
    |> assign(:statuses, [])
  end

  defp run_search(socket, q) do
    viewer_id = socket.assigns.current_profile && socket.assigns.current_profile.id

    tab = socket.assigns.tab
    opts = [limit: @limit]

    # Only query the buckets the active tab renders.
    accounts = if show?(tab, :accounts), do: Search.accounts(q, opts), else: []
    hashtags = if show?(tab, :hashtags), do: Search.hashtags(q, opts), else: []
    statuses = if show?(tab, :statuses), do: Search.statuses(q, viewer_id, opts), else: []

    counts = Hashtags.usage_counts(Enum.map(hashtags, & &1.name))

    socket
    |> assign(:searched?, true)
    |> assign(:accounts, Enum.map(accounts, &Account.render/1))
    |> assign(
      :hashtags,
      Enum.map(hashtags, &%{name: &1.name, count: Map.get(counts, &1.name, 0)})
    )
    |> assign(:statuses, StatusJSON.render_many(statuses, viewer_id))
  end

  defp parse_tab(type) do
    case Enum.find(@tabs, fn {key, _} -> Atom.to_string(key) == type end) do
      {key, _} -> key
      nil -> :all
    end
  end

  defp show?(:all, _section), do: true
  defp show?(tab, section), do: tab == section

  defp empty?(assigns) do
    assigns.accounts == [] and assigns.hashtags == [] and assigns.statuses == []
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <section class="space-y-5">
        <.form for={@form} id="search-form" phx-change="search" phx-submit="search" role="search">
          <label class="input input-bordered flex items-center gap-2 w-full">
            <.icon name="hero-magnifying-glass-micro" class="size-4 opacity-60" />
            <input
              type="search"
              name="q"
              value={@query}
              autocomplete="off"
              phx-debounce="250"
              placeholder="Search people, hashtags, and posts"
              class="grow"
            />
          </label>
        </.form>

        <div :if={@searched?} role="tablist" class="tabs tabs-bordered">
          <.link
            :for={{key, label} <- @tabs}
            role="tab"
            patch={~p"/search?#{%{q: @query, type: key}}"}
            class={["tab", @tab == key && "tab-active font-semibold"]}
          >
            {label}
          </.link>
        </div>

        <p :if={@searched? and empty?(assigns)} class="text-sm text-base-content/60">
          No results for "{@query}".
        </p>

        <p :if={!@searched?} class="text-sm text-base-content/60">
          Start typing to search accounts, hashtags, and posts.
        </p>

        <section :if={show?(@tab, :accounts) and @accounts != []} class="space-y-2">
          <h2
            :if={@tab == :all}
            class="text-xs font-semibold uppercase tracking-wide text-base-content/60"
          >
            People
          </h2>
          <.account_row :for={account <- @accounts} account={account} />
        </section>

        <section :if={show?(@tab, :hashtags) and @hashtags != []} class="space-y-2">
          <h2
            :if={@tab == :all}
            class="text-xs font-semibold uppercase tracking-wide text-base-content/60"
          >
            Hashtags
          </h2>
          <ul class="flex flex-wrap gap-2">
            <li :for={tag <- @hashtags}>
              <.link
                navigate={~p"/tags/#{tag.name}"}
                class="badge badge-lg badge-outline gap-1 hover:badge-primary"
              >
                #{tag.name}
                <span class="opacity-60 tabular-nums">{tag.count}</span>
              </.link>
            </li>
          </ul>
        </section>

        <section :if={show?(@tab, :statuses) and @statuses != []} class="space-y-3">
          <h2
            :if={@tab == :all}
            class="text-xs font-semibold uppercase tracking-wide text-base-content/60"
          >
            Posts
          </h2>
          <.post_card
            :for={status <- @statuses}
            id={"search-post-#{status["id"]}"}
            status={status}
            current_user={@current_user}
          />
        </section>
      </section>
    </Layouts.app>
    """
  end
end
