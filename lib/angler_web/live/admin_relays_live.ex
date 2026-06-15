defmodule AnglerWeb.AdminRelaysLive do
  @moduledoc """
  Admin-only management of ActivityPub relay subscriptions.

  Add a relay by its actor URL (LitePub model — sends a `Follow` of the relay
  actor signed by the instance actor); enable/disable/remove existing ones.
  Backed by `Angler.Federation.Relays`. Gated by `AnglerWeb.LiveAuth`
  `:require_admin`.
  """
  use AnglerWeb, :live_view

  alias Angler.Federation.Relays

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Relays")
     |> assign(:form, to_form(%{"actor_url" => ""}, as: :relay))
     |> load_relays()}
  end

  defp load_relays(socket), do: assign(socket, :relays, Relays.list())

  @impl true
  def handle_event("add", %{"relay" => %{"actor_url" => url}}, socket) do
    case Relays.subscribe(String.trim(url)) do
      {:ok, _relay} ->
        {:noreply,
         socket
         |> put_flash(:info, "Relay added — Follow sent, awaiting Accept.")
         |> assign(:form, to_form(%{"actor_url" => ""}, as: :relay))
         |> load_relays()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't add that relay (#{inspect(reason)}).")}
    end
  end

  def handle_event("enable", %{"id" => id}, socket),
    do: act(socket, id, &Relays.enable/1, "Re-sent Follow.")

  def handle_event("disable", %{"id" => id}, socket),
    do: act(socket, id, &Relays.disable/1, "Disabled — Undo sent.")

  def handle_event("remove", %{"id" => id}, socket) do
    case Relays.get(String.to_integer(id)) do
      nil ->
        {:noreply, socket}

      relay ->
        :ok = Relays.unsubscribe(relay)
        {:noreply, socket |> put_flash(:info, "Relay removed.") |> load_relays()}
    end
  end

  defp act(socket, id, fun, msg) do
    case Relays.get(String.to_integer(id)) do
      nil ->
        {:noreply, socket}

      relay ->
        {:ok, _} = fun.(relay)
        {:noreply, socket |> put_flash(:info, msg) |> load_relays()}
    end
  end

  defp badge(:accepted), do: "badge-success"
  defp badge(:pending), do: "badge-warning"
  defp badge(:idle), do: "badge-ghost"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-2xl space-y-6">
        <h1 class="text-2xl font-bold">ActivityPub relays</h1>

        <div class="alert alert-info text-sm">
          <.icon name="hero-information-circle" class="size-5 shrink-0" />
          <span>
            A relay forwards a firehose of public posts from other instances into your
            federated &amp; hashtag timelines. Add one by its actor URL
            (e.g. <code>https://relay.toot.io/actor</code>).
          </span>
        </div>

        <.form for={@form} phx-submit="add" class="flex items-end gap-2">
          <.input field={@form[:actor_url]} type="url" label="Relay actor URL" class="flex-1" />
          <button type="submit" class="btn btn-primary">Add relay</button>
        </.form>

        <ul :if={@relays != []} class="space-y-2">
          <li :for={relay <- @relays} class="card bg-base-200 border border-base-300">
            <div class="card-body flex-row items-center gap-3 p-3">
              <div class="min-w-0 flex-1">
                <div class="font-mono text-sm truncate">{relay.actor_url}</div>
                <div class="text-xs text-base-content/60 truncate">{relay.inbox_url}</div>
              </div>
              <span class={["badge", badge(relay.state)]}>{relay.state}</span>
              <button
                :if={relay.state == :idle}
                class="btn btn-ghost btn-xs"
                phx-click="enable"
                phx-value-id={relay.id}
              >
                Enable
              </button>
              <button
                :if={relay.state != :idle}
                class="btn btn-ghost btn-xs"
                phx-click="disable"
                phx-value-id={relay.id}
              >
                Disable
              </button>
              <button
                class="btn btn-ghost btn-xs text-error"
                phx-click="remove"
                phx-value-id={relay.id}
                data-confirm="Remove this relay?"
              >
                Remove
              </button>
            </div>
          </li>
        </ul>

        <p :if={@relays == []} class="text-sm text-base-content/60">No relays configured.</p>
      </div>
    </Layouts.app>
    """
  end
end
