defmodule AnglerWeb.AdminInstancesLive do
  @moduledoc """
  Admin-only view of known peer servers: the rows behind the "known servers"
  count on the landing page, with each domain's local footprint (accounts,
  follows, statuses) and federation health. Read-only. Backed by
  `Angler.Federation.Instances`; gated by `AnglerWeb.LiveAuth`
  `:require_admin`.
  """
  use AnglerWeb, :live_view

  alias Angler.Federation.Instances
  alias AnglerWeb.PublicComponents

  @filter_labels %{
    "all" => "All",
    "failing" => "Delivery failing",
    "unreachable" => "Unreachable",
    "banned" => "Banned",
    "limited" => "Limited"
  }

  @sort_labels [
    {"Recently discovered", "recent"},
    {"Most known accounts", "accounts"},
    {"Recently fetched", "fetched"},
    {"Domain A–Z", "domain"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Known servers")
     |> assign(:summary, Instances.summary())
     |> assign(:sort_options, @sort_labels)
     |> assign(:filter_labels, @filter_labels)
     |> stream_configure(:instances, dom_id: &"instance-#{&1.instance.id}")
     |> stream(:instances, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    opts = %{
      "q" => params["q"] || "",
      "filter" => valid(params["filter"], Instances.filters(), "all"),
      "sort" => valid(params["sort"], Instances.sorts(), "recent")
    }

    {:noreply,
     socket
     |> assign(:opts, opts)
     |> assign(:form, to_form(opts, as: :search))
     |> load(0, reset: true)}
  end

  defp valid(v, allowed, default), do: if(v in allowed, do: v, else: default)

  defp load(socket, offset, stream_opts) do
    %{rows: rows, total: total, more?: more?} =
      Instances.list(Map.put(socket.assigns.opts, "offset", offset))

    socket
    |> assign(:total, total)
    |> assign(:offset, offset + length(rows))
    |> assign(:more?, more?)
    |> stream(:instances, rows, stream_opts)
  end

  @impl true
  def handle_event("search", %{"search" => params}, socket) do
    {:noreply, push_patch(socket, to: path(Map.merge(socket.assigns.opts, params)))}
  end

  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, push_patch(socket, to: path(Map.put(socket.assigns.opts, "filter", filter)))}
  end

  def handle_event("more", _params, socket) do
    {:noreply, load(socket, socket.assigns.offset, [])}
  end

  defp path(opts) do
    query =
      opts
      |> Map.take(["q", "filter", "sort"])
      |> Enum.reject(fn {k, v} ->
        v in [nil, ""] or {k, v} in [{"filter", "all"}, {"sort", "recent"}]
      end)

    ~p"/admin/instances?#{query}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-4xl space-y-6">
        <div class="flex items-baseline justify-between gap-3">
          <h1 class="text-2xl font-bold">Known servers</h1>
          <.link navigate={~p"/admin"} class="link text-sm">Admin settings</.link>
        </div>

        <div id="instances-summary" class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
          <.summary_tile label="Known" value={@summary.total} filter="all" active={@opts["filter"]} />
          <.summary_tile label="New this week" value={@summary.new_this_week} />
          <.summary_tile
            label="Delivery failing"
            value={@summary.failing}
            filter="failing"
            active={@opts["filter"]}
            tone="warning"
          />
          <.summary_tile
            label="Unreachable"
            value={@summary.unreachable}
            filter="unreachable"
            active={@opts["filter"]}
            tone="warning"
          />
          <.summary_tile
            label="Banned"
            value={@summary.banned}
            filter="banned"
            active={@opts["filter"]}
            tone="error"
          />
          <.summary_tile
            label="Limited"
            value={@summary.limited}
            filter="limited"
            active={@opts["filter"]}
            tone="info"
          />
        </div>

        <.form
          for={@form}
          id="instances-search"
          phx-change="search"
          phx-submit="search"
          class="flex flex-col gap-2 sm:flex-row sm:items-end"
        >
          <div class="flex-1">
            <.input
              field={@form[:q]}
              type="search"
              placeholder="Search domains…"
              phx-debounce="300"
              autocomplete="off"
            />
          </div>
          <div class="sm:w-56">
            <.input field={@form[:sort]} type="select" options={@sort_options} />
          </div>
        </.form>

        <p id="instances-count" class="text-sm text-base-content/60">
          {@total} {if @total == 1, do: "server", else: "servers"}
          <span :if={@opts["filter"] != "all"}>
            · {@filter_labels[@opts["filter"]]}
            <button type="button" phx-click="filter" phx-value-filter="all" class="link ml-1">
              clear
            </button>
          </span>
        </p>

        <ul id="instances" phx-update="stream" class="space-y-2">
          <li
            id="instances-empty"
            class="hidden only:block text-sm text-base-content/60 py-8 text-center"
          >
            No servers match.
          </li>
          <li
            :for={{id, row} <- @streams.instances}
            id={id}
            class="rounded-box border border-base-300 bg-base-200 transition-colors hover:border-base-content/20"
          >
            <details class="group">
              <summary class="flex cursor-pointer list-none items-center gap-3 p-3">
                <.icon
                  name="hero-chevron-right"
                  class="size-4 shrink-0 text-base-content/40 transition-transform group-open:rotate-90"
                />
                <div class="min-w-0 flex-1">
                  <div class="flex flex-wrap items-center gap-2">
                    <span class="truncate font-mono text-sm font-medium">
                      {row.instance.domain}
                    </span>
                    <.status_badges instance={row.instance} />
                  </div>
                  <div class="text-xs text-base-content/60">
                    {software(row.instance)} · first seen {ago(row.instance.inserted_at)}
                  </div>
                </div>
                <div class="hidden gap-5 text-right sm:flex">
                  <.metric label="accounts" value={row.accounts} />
                  <.metric label="followed" value={row.followed_by_local} />
                  <.metric label="followers" value={row.following_local} />
                  <.metric label="posts" value={row.statuses} />
                </div>
              </summary>

              <div class="space-y-4 border-t border-base-300 p-4 text-sm">
                <div class="grid grid-cols-2 gap-3 sm:hidden">
                  <.metric label="accounts" value={row.accounts} />
                  <.metric label="followed" value={row.followed_by_local} />
                  <.metric label="followers" value={row.following_local} />
                  <.metric label="posts" value={row.statuses} />
                </div>

                <p :if={row.instance.description} class="text-base-content/80">
                  {row.instance.description}
                </p>

                <dl class="grid grid-cols-1 gap-x-6 gap-y-2 sm:grid-cols-2">
                  <.detail label="Known accounts here">
                    {row.accounts} profiles we've fetched from this server
                  </.detail>
                  <.detail label="Follows">
                    {row.followed_by_local} local → them · {row.following_local} them → local
                  </.detail>
                  <.detail label="Posts received">{row.statuses}</.detail>
                  <.detail label="Reported size">
                    {count_or_unknown(row.instance.user_count)} users · {count_or_unknown(
                      row.instance.status_count
                    )} posts
                  </.detail>
                  <.detail label="Registrations">
                    {if row.instance.open_registrations, do: "Open", else: "Closed"}
                  </.detail>
                  <.detail label="First seen">{stamp(row.instance.inserted_at)}</.detail>
                  <.detail label="Metadata fetched">{stamp(row.instance.last_fetched_at)}</.detail>
                  <.detail label="Delivery">{delivery(row.instance)}</.detail>
                  <.detail label="Unreachable since">
                    {stamp(row.instance.unreachable_since)}
                  </.detail>
                  <.detail :if={row.instance.block_sync_url} label="Block sync">
                    <span class="break-all font-mono text-xs">{row.instance.block_sync_url}</span>
                  </.detail>
                  <.detail :if={row.instance.banned} label="Ban">
                    {row.instance.ban_severity || "banned"}{if row.instance.ban_reason,
                      do: " — #{row.instance.ban_reason}"}
                  </.detail>
                  <.detail :if={row.instance.private_comments} label="Private note">
                    {row.instance.private_comments}
                  </.detail>
                </dl>

                <div class="flex flex-wrap gap-3">
                  <a
                    href={"https://#{row.instance.domain}"}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="link text-sm"
                  >
                    Visit <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                  </a>
                </div>
              </div>
            </details>
          </li>
        </ul>

        <div :if={@more?} class="flex justify-center">
          <button
            id="instances-more"
            type="button"
            phx-click="more"
            phx-disable-with="Loading…"
            class="btn btn-ghost btn-sm"
          >
            Load more
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :filter, :string, default: nil
  attr :active, :string, default: nil
  attr :tone, :string, default: nil

  defp summary_tile(%{filter: nil} = assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-200 p-3">
      <div class="text-xl font-bold tabular-nums">{@value}</div>
      <div class="text-xs uppercase tracking-wide text-base-content/60">{@label}</div>
    </div>
    """
  end

  defp summary_tile(assigns) do
    ~H"""
    <button
      type="button"
      id={"instances-filter-#{@filter}"}
      phx-click="filter"
      phx-value-filter={@filter}
      class={[
        "rounded-box border p-3 text-left transition hover:-translate-y-0.5 hover:shadow-sm",
        if(@active == @filter,
          do: "border-primary bg-primary/10",
          else: "border-base-300 bg-base-200 hover:border-base-content/20"
        )
      ]}
    >
      <div class={[
        "text-xl font-bold tabular-nums",
        @value > 0 && tone_class(@tone)
      ]}>
        {@value}
      </div>
      <div class="text-xs uppercase tracking-wide text-base-content/60">{@label}</div>
    </button>
    """
  end

  defp tone_class("warning"), do: "text-warning"
  defp tone_class("error"), do: "text-error"
  defp tone_class("info"), do: "text-info"
  defp tone_class(_), do: nil

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp metric(assigns) do
    ~H"""
    <div class="min-w-14">
      <div class="font-semibold tabular-nums">{@value}</div>
      <div class="text-[10px] uppercase tracking-wide text-base-content/50">{@label}</div>
    </div>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp detail(assigns) do
    ~H"""
    <div>
      <dt class="text-xs uppercase tracking-wide text-base-content/50">{@label}</dt>
      <dd>{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :instance, :map, required: true

  defp status_badges(assigns) do
    ~H"""
    <span :if={@instance.banned} class="badge badge-error badge-sm">banned</span>
    <span :if={@instance.unlisted} class="badge badge-info badge-sm">unlisted</span>
    <span :if={@instance.auto_cw} class="badge badge-info badge-sm">auto CW</span>
    <span :if={@instance.delivery_timeout} class="badge badge-warning badge-sm">backed off</span>
    <span
      :if={not @instance.delivery_timeout and @instance.delivery_failures > 0}
      class="badge badge-warning badge-outline badge-sm"
    >
      {@instance.delivery_failures} failed
    </span>
    <span :if={@instance.unreachable_since} class="badge badge-ghost badge-sm">unreachable</span>
    """
  end

  defp software(%{software: nil}), do: "software unknown"
  defp software(%{software: s, version: nil}), do: s
  defp software(%{software: s, version: v}), do: "#{s} #{v}"

  defp count_or_unknown(nil), do: "?"
  defp count_or_unknown(n), do: n

  defp ago(nil), do: "never"
  defp ago(dt), do: PublicComponents.relative_time(DateTime.to_iso8601(dt))

  defp stamp(nil), do: "—"
  defp stamp(dt), do: "#{Calendar.strftime(dt, "%Y-%m-%d %H:%M")} UTC (#{ago(dt)})"

  defp delivery(%{delivery_timeout: true, delivery_next_after: next} = i) do
    "#{i.delivery_failures} consecutive failures, paused until #{stamp(next)}"
  end

  defp delivery(%{delivery_failures: n}) when n > 0, do: "#{n} consecutive failures"
  defp delivery(_), do: "Healthy"
end
