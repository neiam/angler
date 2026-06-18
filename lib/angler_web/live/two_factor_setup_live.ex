defmodule AnglerWeb.TwoFactorSetupLive do
  @moduledoc """
  Manage two-factor authentication: enroll/disable TOTP, view recovery-code
  status and regenerate them, and register/remove WebAuthn security keys.

  The pending TOTP secret lives only in socket state until the user proves they
  can produce a valid code via `confirm_enrollment`; a half-enrolled secret is
  never persisted, so it can't lock anyone out.
  """
  use AnglerWeb, :live_view

  alias Angler.Accounts
  alias Angler.Accounts.{TwoFactor, Webauthn}

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_user do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/login?next=/settings/two-factor")}

      _user ->
        {:ok,
         socket
         |> assign(:page_title, "Two-factor authentication")
         |> assign(:pending_secret, nil)
         |> assign(:qr, nil)
         |> assign(:recovery_codes, nil)
         |> assign(:error, nil)
         |> load()}
    end
  end

  @impl true
  def handle_event("begin", _params, socket) do
    secret = TwoFactor.new_secret()
    uri = TwoFactor.provisioning_uri(secret, socket.assigns.current_user)

    {:noreply,
     socket
     |> assign(:pending_secret, secret)
     |> assign(:qr, TwoFactor.qr_svg(uri))
     |> assign(:manual_key, Base.encode32(secret, padding: false))
     |> assign(:error, nil)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, pending_secret: nil, qr: nil, error: nil)}
  end

  def handle_event("confirm", %{"code" => code}, socket) do
    case TwoFactor.enable(socket.assigns.current_user, socket.assigns.pending_secret, code) do
      {:ok, codes} ->
        {:noreply,
         socket
         |> assign(:pending_secret, nil)
         |> assign(:qr, nil)
         |> assign(:recovery_codes, codes)
         |> put_flash(:info, "Two-factor authentication is on.")
         |> load()}

      {:error, :invalid_code} ->
        {:noreply, assign(socket, :error, "That code didn't match. Try again.")}
    end
  end

  def handle_event("regenerate", _params, socket) do
    codes = TwoFactor.regenerate_recovery_codes!(socket.assigns.current_user)
    {:noreply, socket |> assign(:recovery_codes, codes) |> load()}
  end

  def handle_event("disable", _params, socket) do
    {:ok, _} = TwoFactor.disable(socket.assigns.current_user)

    {:noreply,
     socket
     |> assign(:recovery_codes, nil)
     |> put_flash(:info, "Two-factor authentication is off.")
     |> load()}
  end

  def handle_event("delete_key", %{"id" => id}, socket) do
    with {int_id, ""} <- Integer.parse(id),
         cred when not is_nil(cred) <-
           Webauthn.get_credential(socket.assigns.current_user, int_id) do
      Webauthn.delete_credential(cred)
    end

    {:noreply, load(socket)}
  end

  defp load(socket) do
    user = Accounts.get_user(socket.assigns.current_user.id)

    socket
    |> assign(:current_user, user)
    |> assign(:totp_enabled, TwoFactor.enabled?(user))
    |> assign(:remaining_codes, TwoFactor.remaining_recovery_codes(user))
    |> assign(:keys, Webauthn.list_credentials(user))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-xl space-y-8">
        <h1 class="text-2xl font-bold">Two-factor authentication</h1>

        <div :if={@recovery_codes} class="alert alert-warning flex-col items-start gap-2">
          <p class="font-semibold">Save your recovery codes</p>
          <p class="text-xs">
            Each works once if you lose your device. This is the only time they're shown.
          </p>
          <div class="grid grid-cols-2 gap-x-6 gap-y-1 font-mono text-sm">
            <span :for={code <- @recovery_codes}>{code}</span>
          </div>
        </div>

        <section class="space-y-3">
          <h2 class="text-lg font-semibold">Authenticator app (TOTP)</h2>

          <%= cond do %>
            <% @pending_secret -> %>
              <div class="card bg-base-200 border border-base-300">
                <div class="card-body gap-3 p-4">
                  <p class="text-sm">Scan this with your authenticator app, then enter the code.</p>
                  <div class="bg-white p-3 rounded-box w-fit mx-auto">{raw(@qr)}</div>
                  <details class="text-xs">
                    <summary class="cursor-pointer">Can't scan? Enter this key</summary>
                    <code class="break-all">{@manual_key}</code>
                  </details>

                  <.form for={%{}} phx-submit="confirm" class="flex gap-2">
                    <input
                      type="text"
                      name="code"
                      inputmode="numeric"
                      autocomplete="one-time-code"
                      placeholder="123456"
                      required
                      class="input input-bordered input-sm flex-1 text-center tracking-widest"
                    />
                    <button type="submit" class="btn btn-primary btn-sm">Confirm</button>
                    <button type="button" phx-click="cancel" class="btn btn-ghost btn-sm">
                      Cancel
                    </button>
                  </.form>
                  <p :if={@error} class="text-sm text-error">{@error}</p>
                </div>
              </div>
            <% @totp_enabled -> %>
              <div class="card bg-base-200 border border-base-300">
                <div class="card-body flex-row items-center gap-3 p-4">
                  <span class="badge badge-success">On</span>
                  <div class="min-w-0 flex-1 text-sm text-base-content/70">
                    {@remaining_codes} recovery codes remaining.
                  </div>
                  <button type="button" phx-click="regenerate" class="btn btn-ghost btn-xs">
                    New codes
                  </button>
                  <button
                    type="button"
                    phx-click="disable"
                    data-confirm="Turn off TOTP?"
                    class="btn btn-error btn-xs"
                  >
                    Turn off
                  </button>
                </div>
              </div>
            <% true -> %>
              <button type="button" phx-click="begin" class="btn btn-primary btn-sm">
                Set up authenticator app
              </button>
          <% end %>
        </section>

        <section class="space-y-3">
          <h2 class="text-lg font-semibold">Security keys</h2>

          <ul :if={@keys != []} class="space-y-2">
            <li :for={key <- @keys} class="card bg-base-200 border border-base-300">
              <div class="card-body flex-row items-center gap-3 p-3">
                <.icon name="hero-finger-print" class="size-5 shrink-0" />
                <div class="min-w-0 flex-1 font-medium truncate">{key.name}</div>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs"
                  phx-click="delete_key"
                  phx-value-id={key.id}
                  data-confirm="Remove this security key?"
                >
                  Remove
                </button>
              </div>
            </li>
          </ul>

          <p :if={@keys == []} class="text-sm text-base-content/50">No security keys registered.</p>

          <button
            type="button"
            id="webauthn-register"
            phx-hook="WebauthnRegister"
            data-start-url={~p"/api/webauthn/register/start"}
            data-finish-url={~p"/api/webauthn/register/finish"}
            data-recovery-target="#webauthn-recovery"
            class="btn btn-outline btn-sm"
          >
            <.icon name="hero-finger-print" class="size-4" /> Add a security key
          </button>
          <p data-status-for="webauthn" class="text-xs text-error"></p>
          <div id="webauthn-recovery" class="hidden"></div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
