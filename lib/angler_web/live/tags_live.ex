defmodule AnglerWeb.TagsLive do
  @moduledoc """
  Popular hashtags at `/tags`: the most used tags this week, with tabs for
  today, this month, this year and all time at `/tags/top/:period`. Counts
  come from `Angler.Trends.top_tags/2`, so they match what each tag page
  shows. Each row links to the tag page.
  """
  use AnglerWeb, :live_view

  alias Angler.Trends

  @default "week"
  @labels %{
    "today" => "Today",
    "week" => "This week",
    "month" => "This month",
    "year" => "This year",
    "all" => "All time"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Popular tags")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period = params["period"] || @default

    if period in Trends.periods() do
      tags = Trends.top_tags(period)

      {:noreply,
       socket
       |> assign(:period, period)
       |> assign(:tags, tags)
       |> assign(:max_uses, tags |> Enum.map(& &1.uses) |> Enum.max(fn -> 1 end))}
    else
      {:noreply, push_patch(socket, to: ~p"/tags", replace: true)}
    end
  end

  defp period_path(@default), do: ~p"/tags"
  defp period_path(period), do: ~p"/tags/top/#{period}"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :labels, @labels)

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <section id="tags-index" class="space-y-6">
        <h1 class="text-3xl font-bold tracking-tight">Popular tags</h1>

        <nav id="tag-periods" role="tablist" class="tabs tabs-box w-fit flex-wrap">
          <.link
            :for={p <- Trends.periods()}
            id={"period-#{p}"}
            patch={period_path(p)}
            replace
            role="tab"
            aria-selected={to_string(p == @period)}
            class={["tab", p == @period && "tab-active"]}
          >
            {@labels[p]}
          </.link>
        </nav>

        <ol :if={@tags != []} id="top-tags" class="space-y-2">
          <li :for={{t, rank} <- Enum.with_index(@tags, 1)} id={"top-tag-#{t.tag.name}"}>
            <.link
              navigate={~p"/tags/#{t.tag.name}"}
              class="group relative flex items-center gap-4 overflow-hidden rounded-box border border-base-300 bg-base-200 px-4 py-3 transition hover:border-primary/50"
            >
              <%!-- Popularity bar, relative to the top tag in this period. --%>
              <span
                aria-hidden="true"
                class="absolute inset-y-0 left-0 bg-primary/10 transition-colors group-hover:bg-primary/15"
                style={"width: #{round(t.uses / @max_uses * 100)}%"}
              />
              <span class="relative w-6 text-right text-sm tabular-nums text-base-content/50">
                {rank}
              </span>
              <span class="relative min-w-0 flex-1 truncate font-semibold group-hover:text-primary">
                #{t.tag.name}
              </span>
              <span :if={t.tag.nsfw} class="relative badge badge-warning badge-xs">NSFW</span>
              <span class="relative text-right text-xs text-base-content/60 tabular-nums">
                <span class="font-medium text-base-content">{t.uses}</span>
                {if t.uses == 1, do: "post", else: "posts"}
                <span class="hidden sm:inline">
                  · {t.accounts} {if t.accounts == 1, do: "person", else: "people"}
                </span>
              </span>
            </.link>
          </li>
        </ol>

        <p :if={@tags == []} id="no-tags" class="text-sm text-base-content/60">
          No tagged photos in this period.
        </p>
      </section>
    </Layouts.app>
    """
  end
end
