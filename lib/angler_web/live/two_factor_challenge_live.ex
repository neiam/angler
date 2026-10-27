defmodule AnglerWeb.TwoFactorChallengeLive do
  @moduledoc """
  Second-factor step of login. Reached after `SessionController.create/2`
  verifies the password and finds the account has a factor enabled; it stashes a
  *pending* `:two_factor_user_id` in the session and redirects here.

  On a valid TOTP or recovery code we mint a short-lived signed token and do a
  full-page redirect to `SessionController.complete_two_factor/2`, which promotes
  the pending login to a real session (a LiveView can't write the cookie). The
  WebAuthn path is handled entirely by the JS hook + `/api/webauthn/auth/*`,
  which sets its own session proof before redirecting to the same completion URL.
  """
  use AnglerWeb, :live_view

  alias Angler.Accounts
  alias Angler.Accounts.{TwoFactor, Webauthn}

  @token_salt "two-factor-complete"

  @impl true
  def mount(_params, session, socket) do
    case session["two_factor_user_id"] && Accounts.get_user(session["two_factor_user_id"]) do
      %{} = user ->
        {:ok,
         socket
         |> assign(:page_title, "Two-factor authentication")
         |> assign(:user, user)
         |> assign(:totp?, TwoFactor.enabled?(user))
         |> assign(:webauthn?, Webauthn.has_credentials?(user))
         |> assign(:mode, if(TwoFactor.enabled?(user), do: :totp, else: :recovery))
         |> assign(:error, nil)}

      _ ->
        {:ok, push_navigate(socket, to: ~p"/login")}
    end
  end

  @impl true
  def handle_event("switch", %{"mode" => mode}, socket) when mode in ["totp", "recovery"] do
    {:noreply, assign(socket, mode: String.to_existing_atom(mode), error: nil)}
  end

  # 5 tries per 15 minutes per pending login (upstream 8cebb24c0): a TOTP
  # code has 10^6 values, so an unthrottled form is guessable.
  @two_factor_limit 5
  @two_factor_window_s 900

  def handle_event("verify", %{"code" => code}, socket) do
    user = socket.assigns.user
    limit_key = {:two_factor, user.id}

    result =
      cond do
        not Angler.RateLimit.allowed?(limit_key, @two_factor_limit, @two_factor_window_s) ->
          :rate_limited

        socket.assigns.mode == :totp ->
          TwoFactor.verify_code(user, String.trim(code))

        true ->
          TwoFactor.verify_recovery_code(user, code)
      end

    case result do
      :rate_limited ->
        {:noreply, assign(socket, :error, "Too many attempts. Wait a few minutes and try again.")}

      :ok ->
        Angler.RateLimit.reset(limit_key)
        token = Phoenix.Token.sign(socket, @token_salt, user.id)
        {:noreply, redirect(socket, to: ~p"/login/two-factor/complete?#{[token: token]}")}

      {:error, _} ->
        Angler.RateLimit.fail(limit_key, @two_factor_window_s)
        {:noreply, assign(socket, :error, "That code didn't match. Try again.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-sm space-y-6">
        <h1 class="text-2xl font-bold text-center">Two-factor authentication</h1>

        <p class="text-sm text-center text-base-content/70">
          <%= if @mode == :totp do %>
            Enter the 6-digit code from your authenticator app.
          <% else %>
            Enter one of your recovery codes.
          <% end %>
        </p>

        <.form for={%{}} id="two-factor-form" phx-submit="verify" class="space-y-4">
          <input
            type="text"
            name="code"
            inputmode={if @mode == :totp, do: "numeric", else: "text"}
            autocomplete="one-time-code"
            autofocus
            required
            placeholder={if @mode == :totp, do: "123456", else: "recovery code"}
            class="input input-bordered w-full text-center tracking-widest"
          />

          <p :if={@error} class="text-sm text-error">{@error}</p>

          <button type="submit" class="btn btn-primary w-full" phx-disable-with="Verifying…">
            Verify
          </button>
        </.form>

        <div :if={@webauthn?} class="space-y-2">
          <div class="divider text-xs">or</div>
          <button
            type="button"
            id="webauthn-authenticate"
            phx-hook="WebauthnAuthenticate"
            data-complete-url={~p"/login/two-factor/complete"}
            class="btn btn-outline w-full"
          >
            <.icon name="hero-finger-print" class="size-5" /> Use a security key
          </button>
          <p data-status-for="webauthn" class="text-center text-xs text-error"></p>
        </div>

        <div class="text-center text-sm">
          <button
            :if={@totp? and @mode == :recovery}
            type="button"
            phx-click="switch"
            phx-value-mode="totp"
            class="link link-hover text-base-content/60"
          >
            Use your authenticator app instead
          </button>
          <button
            :if={@mode == :totp}
            type="button"
            phx-click="switch"
            phx-value-mode="recovery"
            class="link link-hover text-base-content/60"
          >
            Use a recovery code instead
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
