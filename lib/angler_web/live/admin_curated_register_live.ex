defmodule AnglerWeb.AdminCuratedRegisterLive do
  @moduledoc """
  One curated-registration application (upstream
  `AdminCuratedRegisterController::show` and its `api*` actions): the
  applicant's details and reason, the message thread, and the admin
  actions: approve, reject (with an optional note, or silently), and request
  more details.

  Gated by `AnglerWeb.LiveAuth` `:require_admin`.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.AdminCuratedRegistersLive, only: [status_badge: 1]

  alias Angler.CuratedRegistrations

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case CuratedRegistrations.get(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Application not found.")
         |> push_navigate(to: ~p"/admin/curated-onboarding")}

      record ->
        {:ok,
         socket
         |> assign(:page_title, "Application @#{record.username}")
         |> assign_record(record)}
    end
  end

  defp assign_record(socket, record) do
    socket
    |> assign(:record, record)
    |> assign(:reject_form, to_form(%{"message" => "", "notify" => "true"}, as: :reject))
    |> assign(:details_form, to_form(%{"message" => ""}, as: :details))
  end

  defp reload(socket),
    do: assign_record(socket, CuratedRegistrations.get(socket.assigns.record.id))

  @impl true
  def handle_event("approve", _params, socket) do
    case CuratedRegistrations.approve(socket.assigns.record, socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Approved — account created.") |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't approve: #{describe(reason)}.")}
    end
  end

  def handle_event("reject", %{"reject" => params}, socket) do
    opts = [notify: params["notify"] == "true", message: params["message"]]

    case CuratedRegistrations.reject(socket.assigns.record, socket.assigns.current_user, opts) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Application rejected.") |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't reject: #{describe(reason)}.")}
    end
  end

  def handle_event("request_details", %{"details" => %{"message" => message}}, socket) do
    case CuratedRegistrations.request_details(
           socket.assigns.record,
           socket.assigns.current_user,
           message
         ) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Request sent to the applicant.") |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't send: #{describe(reason)}.")}
    end
  end

  defp describe(:unverified), do: "the applicant hasn't confirmed their email"
  defp describe(:closed), do: "the application is already closed"
  defp describe(:invalid_message), do: "the message must be 5 to 3000 characters"

  defp describe(%Ecto.Changeset{} = cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp describe(other), do: inspect(other)

  defp stamp(nil), do: "—"
  defp stamp(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  defp actionable?(record), do: not record.is_closed and not is_nil(record.email_verified_at)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-3xl space-y-6">
        <.link
          navigate={~p"/admin/curated-onboarding"}
          class="btn btn-ghost btn-sm gap-1 -ml-2"
        >
          <.icon name="hero-arrow-left-micro" class="size-4" /> All applications
        </.link>

        <div id="curated-record" class="card bg-base-200 border border-base-300">
          <div class="card-body p-5 space-y-4">
            <div class="flex flex-wrap items-center gap-3">
              <h1 class="text-xl font-bold">@{@record.username}</h1>
              <.status_badge record={@record} />
            </div>
            <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
              <dt class="text-base-content/60">Email</dt>
              <dd class="break-all">{@record.email}</dd>
              <dt class="text-base-content/60">IP address</dt>
              <dd>{@record.ip_address || "—"}</dd>
              <dt class="text-base-content/60">Applied</dt>
              <dd>{stamp(@record.inserted_at)}</dd>
              <dt class="text-base-content/60">Email verified</dt>
              <dd>{stamp(@record.email_verified_at)}</dd>
              <dt :if={@record.action_taken_at} class="text-base-content/60">Decided</dt>
              <dd :if={@record.action_taken_at}>{stamp(@record.action_taken_at)}</dd>
            </dl>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">
                Reason to join
              </div>
              <p id="curated-reason" class="whitespace-pre-wrap">{@record.reason_to_join}</p>
            </div>
          </div>
        </div>

        <section :if={@record.activities != []} class="space-y-2">
          <h2 class="font-semibold">Messages</h2>
          <ol id="curated-thread" class="space-y-2">
            <li
              :for={a <- @record.activities}
              id={"curated-activity-#{a.id}"}
              class={[
                "rounded-box p-3 text-sm border",
                if(a.from_admin,
                  do: "bg-base-200 border-base-300",
                  else: "bg-primary/5 border-primary/20 ml-6"
                )
              ]}
            >
              <div class="text-xs text-base-content/60 mb-1">
                {if a.from_admin, do: "Admin requested details", else: "Applicant replied"} · {stamp(
                  a.inserted_at
                )}
              </div>
              <p class="whitespace-pre-wrap">{a.message}</p>
            </li>
          </ol>
        </section>

        <div :if={is_nil(@record.email_verified_at)} class="alert alert-warning text-sm">
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
          <span>The applicant hasn't confirmed their email yet, so no action can be taken.</span>
        </div>

        <%= if actionable?(@record) do %>
          <div class="flex flex-wrap gap-2">
            <button
              id="curated-approve"
              class="btn btn-success"
              phx-click="approve"
              data-confirm={"Approve @#{@record.username} and create the account?"}
            >
              <.icon name="hero-check-micro" class="size-4" /> Approve
            </button>
          </div>

          <div class="grid gap-4 sm:grid-cols-2">
            <.form
              for={@details_form}
              id="curated-details-form"
              phx-submit="request_details"
              class="card bg-base-200 border border-base-300"
            >
              <div class="card-body p-4 space-y-3">
                <h2 class="font-semibold">Request more details</h2>
                <.input
                  field={@details_form[:message]}
                  type="textarea"
                  label="Message to the applicant"
                  rows="4"
                  required
                />
                <button type="submit" class="btn btn-sm btn-primary">Send request</button>
              </div>
            </.form>

            <.form
              for={@reject_form}
              id="curated-reject-form"
              phx-submit="reject"
              class="card bg-base-200 border border-base-300"
            >
              <div class="card-body p-4 space-y-3">
                <h2 class="font-semibold">Reject</h2>
                <.input
                  field={@reject_form[:message]}
                  type="textarea"
                  label="Note for the applicant (optional)"
                  rows="4"
                />
                <.input
                  field={@reject_form[:notify]}
                  type="checkbox"
                  label="Email the applicant"
                />
                <button
                  type="submit"
                  class="btn btn-sm btn-error"
                  data-confirm="Reject this application?"
                >
                  Reject application
                </button>
              </div>
            </.form>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
