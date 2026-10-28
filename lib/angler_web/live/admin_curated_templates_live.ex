defmodule AnglerWeb.AdminCuratedTemplatesLive do
  @moduledoc """
  Reply templates for curated-registration review (upstream
  `AdminCuratedRegisterController::templates` and its create / edit /
  delete pages, on one page). Active templates show up as a picker on each
  application's "request more details" and "reject" forms.

  Gated by `AnglerWeb.LiveAuth` `:require_admin`.
  """
  use AnglerWeb, :live_view

  alias Angler.CuratedRegistrations
  alias Angler.CuratedRegistrations.Template

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Reply templates")
     |> load()
     |> edit(%Template{})}
  end

  defp load(socket), do: assign(socket, :templates, CuratedRegistrations.list_templates())

  defp edit(socket, %Template{} = template) do
    socket
    |> assign(:editing, template)
    |> assign(:form, to_form(CuratedRegistrations.change_template(template)))
  end

  @impl true
  def handle_event("new", _params, socket), do: {:noreply, edit(socket, %Template{})}

  def handle_event("edit", %{"id" => id}, socket) do
    case CuratedRegistrations.get_template(id) do
      nil -> {:noreply, socket}
      t -> {:noreply, edit(socket, t)}
    end
  end

  def handle_event("validate", %{"template" => params}, socket) do
    cs = CuratedRegistrations.change_template(socket.assigns.editing, params)
    {:noreply, assign(socket, :form, to_form(cs, action: :validate))}
  end

  def handle_event("save", %{"template" => params}, socket) do
    case CuratedRegistrations.save_template(socket.assigns.editing, params) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Template saved.") |> load() |> edit(%Template{})}

      {:error, cs} ->
        {:noreply, assign(socket, :form, to_form(cs, action: :insert))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %Template{} = t <- CuratedRegistrations.get_template(id),
         {:ok, _} <- CuratedRegistrations.delete_template(t) do
      {:noreply, socket |> put_flash(:info, "Template deleted.") |> load() |> edit(%Template{})}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-3xl space-y-6">
        <div class="flex items-center justify-between gap-3">
          <div>
            <.link navigate={~p"/admin/curated-onboarding"} class="link text-sm">
              ← Applications
            </.link>
            <h1 class="text-2xl font-bold">Reply templates</h1>
          </div>
          <button id="new-template" type="button" phx-click="new" class="btn btn-sm btn-ghost">
            <.icon name="hero-plus" class="size-4" /> New template
          </button>
        </div>

        <div class="grid gap-6 md:grid-cols-2">
          <ul id="templates" class="space-y-2">
            <li :if={@templates == []} id="templates-empty" class="alert text-sm">
              No templates yet.
            </li>
            <li
              :for={t <- @templates}
              id={"template-#{t.id}"}
              class={[
                "card border transition-colors hover:border-base-content/20",
                if(@editing.id == t.id,
                  do: "border-primary bg-base-200",
                  else: "border-base-300 bg-base-200/60"
                )
              ]}
            >
              <div class="card-body flex-row items-start gap-3 p-3">
                <button
                  type="button"
                  phx-click="edit"
                  phx-value-id={t.id}
                  class="min-w-0 flex-1 text-left"
                >
                  <span class="flex items-center gap-2 font-semibold">
                    {t.name}
                    <span :if={!t.is_active} class="badge badge-ghost badge-xs">inactive</span>
                  </span>
                  <span :if={t.description} class="block truncate text-xs text-base-content/60">
                    {t.description}
                  </span>
                </button>
                <button
                  type="button"
                  id={"delete-template-#{t.id}"}
                  phx-click="delete"
                  phx-value-id={t.id}
                  data-confirm={"Delete the template \"#{t.name}\"?"}
                  class="btn btn-ghost btn-xs text-error"
                >
                  Delete
                </button>
              </div>
            </li>
          </ul>

          <.form
            for={@form}
            id="template-form"
            phx-change="validate"
            phx-submit="save"
            class="card bg-base-200 border border-base-300"
          >
            <div class="card-body p-4 space-y-3">
              <h2 class="font-semibold">
                {if @editing.id, do: "Edit template", else: "New template"}
              </h2>
              <.input field={@form[:name]} label="Name" maxlength="30" required />
              <.input field={@form[:description]} label="Description (admins only)" />
              <.input field={@form[:content]} type="textarea" label="Message" rows="6" required />
              <.input field={@form[:order]} type="number" label="Order" />
              <.input field={@form[:is_active]} type="checkbox" label="Offer while reviewing" />
              <button type="submit" class="btn btn-sm btn-primary" phx-disable-with="Saving…">
                Save template
              </button>
            </div>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
