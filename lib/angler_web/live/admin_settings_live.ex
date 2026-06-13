defmodule AnglerWeb.AdminSettingsLive do
  @moduledoc """
  Admin-only settings: edit the instance metadata shown on the about page
  (title, descriptions, contact, rules) and manage the admin team. Backed by
  `Angler.Instance` (DB overrides env) and `Angler.Accounts.set_admin/2`.

  Gated by `AnglerWeb.LiveAuth` `:require_admin`.
  """
  use AnglerWeb, :live_view

  alias Angler.Accounts
  alias Angler.Instance

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin settings")
     |> assign_settings_form()
     |> assign_admins()}
  end

  defp assign_settings_form(socket) do
    s = Instance.get_settings()

    data = %{
      "title" => s.title || "",
      "short_description" => s.short_description || "",
      "description" => s.description || "",
      "contact_email" => s.contact_email || "",
      "contact_username" => s.contact_username || "",
      "rules" => Enum.join(s.rules || [], "\n")
    }

    assign(socket, :settings_form, to_form(data, as: :settings))
  end

  defp assign_admins(socket), do: assign(socket, :admins, Accounts.list_admins())

  @impl true
  def handle_event("save_settings", %{"settings" => params}, socket) do
    attrs = Map.put(params, "rules", split_lines(params["rules"]))

    case Instance.update_settings(attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Instance settings saved.")
         |> assign_settings_form()}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't save: #{changeset_error(changeset)}")}
    end
  end

  def handle_event("promote", %{"username" => username}, socket) do
    case Accounts.lookup_by_handle(String.trim(username)) do
      %{} = user ->
        {:ok, _} = Accounts.set_admin(user, true)

        {:noreply,
         socket |> put_flash(:info, "Granted admin to @#{username}.") |> assign_admins()}

      _ ->
        {:noreply, put_flash(socket, :error, "No active local user @#{username}.")}
    end
  end

  def handle_event("demote", %{"username" => username}, socket) do
    cond do
      username == socket.assigns.current_profile.username ->
        {:noreply, put_flash(socket, :error, "You can't remove your own admin access.")}

      true ->
        case Accounts.lookup_by_handle(username) do
          %{} = user ->
            {:ok, _} = Accounts.set_admin(user, false)

            {:noreply,
             socket |> put_flash(:info, "Removed admin from @#{username}.") |> assign_admins()}

          _ ->
            {:noreply, assign_admins(socket)}
        end
    end
  end

  defp split_lines(nil), do: []

  defp split_lines(s) when is_binary(s),
    do: s |> String.split(["\r\n", "\n"]) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp changeset_error(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {f, msgs} -> "#{f} #{Enum.join(msgs, ", ")}" end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-2xl space-y-8">
        <h1 class="text-2xl font-bold">Admin settings</h1>

        <section class="space-y-4">
          <h2 class="text-lg font-semibold">Instance</h2>
          <p class="text-sm text-base-content/60">
            Shown on the public about page. Leave a field blank to fall back to the
            environment configuration.
          </p>

          <.form for={@settings_form} phx-submit="save_settings" class="space-y-4">
            <.input field={@settings_form[:title]} label="Title" maxlength="120" />
            <.input
              field={@settings_form[:short_description]}
              label="Short description"
              maxlength="280"
            />
            <.input field={@settings_form[:description]} type="textarea" label="About / description" />
            <.input field={@settings_form[:contact_email]} type="email" label="Contact email" />
            <.input
              field={@settings_form[:contact_username]}
              label="Contact account (username)"
              placeholder="e.g. admin"
            />
            <.input
              field={@settings_form[:rules]}
              type="textarea"
              label="Server rules (one per line)"
            />
            <button type="submit" class="btn btn-primary" phx-disable-with="Saving…">
              Save instance settings
            </button>
          </.form>
        </section>

        <section class="space-y-4">
          <h2 class="text-lg font-semibold">Administrators</h2>

          <form phx-submit="promote" class="flex gap-2 items-end">
            <div class="flex-1">
              <label class="label"><span class="label-text">Grant admin to username</span></label>
              <input name="username" placeholder="username" class="input w-full" required />
            </div>
            <button type="submit" class="btn btn-secondary">Promote</button>
          </form>

          <ul class="divide-y divide-base-300 rounded-box border border-base-300">
            <li
              :for={admin <- @admins}
              class="flex items-center justify-between gap-3 px-3 py-2"
            >
              <.link navigate={~p"/@#{admin.username}"} class="min-w-0">
                <span class="font-medium">{admin.name || admin.username}</span>
                <span class="text-xs text-base-content/60">@{admin.username}</span>
              </.link>
              <button
                :if={admin.username != @current_profile.username}
                phx-click="demote"
                phx-value-username={admin.username}
                data-confirm={"Remove admin from @#{admin.username}?"}
                class="btn btn-ghost btn-xs text-error"
              >
                Remove
              </button>
              <span
                :if={admin.username == @current_profile.username}
                class="text-xs text-base-content/50"
              >
                you
              </span>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
