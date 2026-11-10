defmodule AnglerWeb.FiltersLive do
  @moduledoc """
  Authenticated settings page for content filtering: keyword filters
  (`Angler.Filters`) and muted hashtags (`Angler.Hashtags.Muting`).

  Each filter/mute carries an action — `blur` (gate behind a click),
  `warn` (gate behind a content-warning summary), or `hide` (drop from feeds).
  Enforcement happens at render time in `Angler.Filters.Matching`.
  """
  use AnglerWeb, :live_view

  alias Angler.Filters
  alias Angler.Hashtags
  alias Angler.Hashtags.Muting

  @actions ~w(blur warn hide)

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_profile do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/login?next=/settings/filters")}

      profile ->
        {:ok,
         socket
         |> assign(:page_title, "Filters")
         |> assign(:actions, @actions)
         |> load(profile)}
    end
  end

  @impl true
  def handle_event("add_keyword", %{"keyword" => kw, "action" => action} = params, socket) do
    profile = socket.assigns.current_profile
    title = blank_to(params["title"], kw)

    if String.trim(kw) == "" do
      {:noreply, put_flash(socket, :error, "Enter a word or phrase to filter.")}
    else
      attrs = %{
        "title" => title,
        "filter_action" => action,
        "contexts" => Angler.Filters.Filter.contexts(),
        "keywords_attributes" => [%{"keyword" => String.trim(kw)}]
      }

      case Filters.create(profile.id, attrs) do
        {:ok, _} -> {:noreply, socket |> put_flash(:info, "Filter added.") |> load(profile)}
        {:error, _} -> {:noreply, put_flash(socket, :error, "Couldn't add that filter.")}
      end
    end
  end

  def handle_event("delete_filter", %{"id" => id}, socket) do
    profile = socket.assigns.current_profile

    with {int_id, ""} <- Integer.parse(id),
         %_{} = filter <- Filters.get(profile.id, int_id) do
      :ok = Filters.delete(filter)
    end

    {:noreply, load(socket, profile)}
  end

  def handle_event("add_mute", %{"hashtag" => name, "action" => action}, socket) do
    profile = socket.assigns.current_profile
    name = name |> String.trim() |> String.trim_leading("#")

    cond do
      name == "" ->
        {:noreply, put_flash(socket, :error, "Enter a hashtag to mute.")}

      action not in @actions ->
        {:noreply, put_flash(socket, :error, "Pick a filter action.")}

      true ->
        case Muting.mute(profile, name, action) do
          {:ok, _} -> {:noreply, socket |> put_flash(:info, "Hashtag muted.") |> load(profile)}
          {:error, _} -> {:noreply, put_flash(socket, :error, "Couldn't mute that hashtag.")}
        end
    end
  end

  def handle_event("unmute", %{"name" => name}, socket) do
    profile = socket.assigns.current_profile
    :ok = Muting.unmute(profile, name)
    {:noreply, load(socket, profile)}
  end

  defp load(socket, profile) do
    filters =
      profile.id
      |> Filters.list()
      |> Enum.map(fn f ->
        %{
          id: f.id,
          title: f.title,
          action: f.filter_action,
          keywords: Enum.map(f.keywords, & &1.keyword)
        }
      end)

    muted = Muting.list(profile.id)
    counts = Hashtags.usage_counts(Enum.map(muted, fn {tag, _action} -> tag.name end))

    mutes =
      Enum.map(muted, fn {tag, action} ->
        %{name: tag.name, action: action, count: Map.fetch!(counts, tag.name)}
      end)

    socket |> assign(:filters, filters) |> assign(:mutes, mutes)
  end

  defp blank_to(nil, fallback), do: fallback
  defp blank_to("", fallback), do: fallback
  defp blank_to(v, _fallback), do: v

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-xl space-y-8">
        <div>
          <h1 class="text-2xl font-bold">Filters</h1>
          <p class="mt-1 text-sm text-base-content/70">
            Blur, warn, or hide posts that match a word or hashtag.
            <span class="font-medium">Blur</span>
            and <span class="font-medium">warn</span>
            keep the post behind a click; <span class="font-medium">hide</span>
            removes it from your feeds.
          </p>
        </div>

        <section class="space-y-3">
          <h2 class="text-lg font-semibold">Keyword filters</h2>

          <form phx-submit="add_keyword" class="card bg-base-200 border border-base-300">
            <div class="card-body gap-3 p-4">
              <input
                type="text"
                name="keyword"
                placeholder="Word or phrase to filter"
                class="input input-bordered input-sm w-full"
                required
              />
              <input
                type="text"
                name="title"
                placeholder="Label (optional)"
                class="input input-bordered input-sm w-full"
              />
              <div class="flex items-center gap-2">
                <.action_select />
                <button type="submit" class="btn btn-primary btn-sm ml-auto">Add filter</button>
              </div>
            </div>
          </form>

          <ul :if={@filters != []} class="space-y-2">
            <li :for={f <- @filters} class="card bg-base-200 border border-base-300">
              <div class="card-body flex-row items-center gap-3 p-3">
                <div class="min-w-0 flex-1">
                  <div class="font-semibold truncate">{f.title}</div>
                  <div class="text-xs text-base-content/60 truncate">
                    {Enum.join(f.keywords, ", ")}
                  </div>
                </div>
                <.action_badge action={f.action} />
                <button
                  type="button"
                  class="btn btn-ghost btn-xs"
                  phx-click="delete_filter"
                  phx-value-id={f.id}
                >
                  Remove
                </button>
              </div>
            </li>
          </ul>

          <p :if={@filters == []} class="text-sm text-base-content/50">No keyword filters yet.</p>
        </section>

        <section class="space-y-3">
          <h2 class="text-lg font-semibold">Muted hashtags</h2>

          <form phx-submit="add_mute" class="card bg-base-200 border border-base-300">
            <div class="card-body flex-row items-center gap-2 p-4">
              <input
                type="text"
                name="hashtag"
                placeholder="hashtag"
                class="input input-bordered input-sm flex-1"
                required
              />
              <.action_select />
              <button type="submit" class="btn btn-primary btn-sm">Mute</button>
            </div>
          </form>

          <ul :if={@mutes != []} class="space-y-2">
            <li :for={m <- @mutes} class="card bg-base-200 border border-base-300">
              <div class="card-body flex-row items-center gap-3 p-3">
                <.link
                  navigate={~p"/tags/#{m.name}"}
                  class="min-w-0 flex-1 font-semibold hover:underline"
                >
                  #{m.name}
                </.link>
                <span class="text-xs text-base-content/60 whitespace-nowrap tabular-nums">
                  {m.count} posts
                </span>
                <.action_badge action={m.action} />
                <button
                  type="button"
                  class="btn btn-ghost btn-xs"
                  phx-click="unmute"
                  phx-value-name={m.name}
                >
                  Unmute
                </button>
              </div>
            </li>
          </ul>

          <p :if={@mutes == []} class="text-sm text-base-content/50">No muted hashtags yet.</p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp action_select(assigns) do
    ~H"""
    <select name="action" class="select select-bordered select-sm">
      <option value="hide">Hide</option>
      <option value="warn">Warn</option>
      <option value="blur">Blur</option>
    </select>
    """
  end

  attr :action, :string, required: true

  defp action_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm whitespace-nowrap",
      @action == "hide" && "badge-error",
      @action == "warn" && "badge-warning",
      @action == "blur" && "badge-info"
    ]}>
      {@action}
    </span>
    """
  end
end
