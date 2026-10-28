defmodule AnglerWeb.AdminCuratedRegistersLive do
  @moduledoc """
  Admin review queue for curated registration (upstream
  `AdminCuratedRegisterController::index`, `admin/curated-register/index`),
  with upstream's filters: open, responses, awaiting, approved, rejected, all.
  Each row links to `AnglerWeb.AdminCuratedRegisterLive`.

  Gated by `AnglerWeb.LiveAuth` `:require_admin`.
  """
  use AnglerWeb, :live_view

  alias Angler.CuratedRegistrations
  alias Angler.CuratedRegistrations.CuratedRegister

  @labels %{
    "open" => "Open",
    "responses" => "Responses",
    "awaiting" => "Awaiting user",
    "approved" => "Approved",
    "rejected" => "Rejected",
    "all" => "All"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Curated onboarding")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter =
      if params["filter"] in CuratedRegistrations.filters(), do: params["filter"], else: "open"

    records = CuratedRegistrations.list(filter)

    {:noreply,
     socket
     |> assign(:filter, filter)
     |> assign(:empty?, records == [])
     |> stream(:records, records, reset: true)}
  end

  defp label(filter), do: Map.fetch!(@labels, filter)

  @doc false
  def status_badge(assigns) do
    {text, class} =
      case CuratedRegister.status(assigns.record) do
        :awaiting_admin -> {"Awaiting admin response", "badge-warning"}
        :unverified -> {"Unverified email", "badge-error badge-outline"}
        :approved -> {"Approved", "badge-success"}
        :rejected -> {"Rejected", "badge-error"}
        :awaiting_user -> {"Awaiting user response", "badge-info badge-outline"}
        :closed -> {"Closed", "badge-ghost"}
        :open -> {"Open", "badge-success badge-outline"}
      end

    assigns = assign(assigns, text: text, class: class)

    ~H"""
    <span class={["badge badge-sm whitespace-nowrap", @class]}>{@text}</span>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-3xl space-y-6">
        <div class="space-y-1">
          <h1 class="text-2xl font-bold">Curated onboarding</h1>
          <p class="text-sm text-base-content/60">
            Applications for new accounts. Approving one creates the account and emails the
            applicant.
          </p>
        </div>

        <div id="curated-filters" role="tablist" class="tabs tabs-box tabs-sm flex-wrap">
          <.link
            :for={f <- CuratedRegistrations.filters()}
            id={"curated-filter-#{f}"}
            patch={~p"/admin/curated-onboarding?#{[filter: f]}"}
            role="tab"
            class={["tab transition-colors", f == @filter && "tab-active"]}
          >
            {label(f)}
          </.link>
        </div>

        <ul id="curated-records" phx-update="stream" class="space-y-2">
          <li :for={{id, record} <- @streams.records} id={id}>
            <.link
              navigate={~p"/admin/curated-onboarding/#{record.id}"}
              class="card bg-base-200 border border-base-300 hover:border-primary/50 transition-colors"
            >
              <div class="card-body flex-row items-center gap-3 p-3">
                <div class="min-w-0 flex-1">
                  <div class="font-medium truncate">@{record.username}</div>
                  <div class="text-xs text-base-content/60 truncate">{record.email}</div>
                </div>
                <time class="text-xs text-base-content/60 hidden sm:block">
                  {Calendar.strftime(record.inserted_at, "%Y-%m-%d")}
                </time>
                <.status_badge record={record} />
                <.icon name="hero-chevron-right-micro" class="size-4 text-base-content/40" />
              </div>
            </.link>
          </li>
        </ul>

        <p :if={@empty?} id="curated-empty" class="text-sm text-base-content/60">
          No applications here.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
