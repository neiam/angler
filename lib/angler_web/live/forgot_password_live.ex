defmodule AnglerWeb.ForgotPasswordLive do
  @moduledoc """
  Request a password-reset link. Responds the same way whether or not the
  email maps to an account, so it can't be used to enumerate addresses.
  Guarded by the captcha when it is active on `:forgot_password` (upstream
  `ForgotPasswordController`).
  """
  use AnglerWeb, :live_view

  import AnglerWeb.AntiSpamComponents

  alias Angler.Accounts
  alias Angler.Captcha

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_user do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Reset password")
       |> assign(:sent?, false)
       |> assign(:error, nil)
       |> assign(:captcha, Captcha.active_on?(:forgot_password) && Captcha.widget())
       |> assign(:form, to_form(%{"email" => ""}))}
    end
  end

  @impl true
  def handle_event("submit", %{"email" => email} = params, socket) do
    case Captcha.check(:forgot_password, params) do
      :ok ->
        Accounts.deliver_password_reset(email)
        {:noreply, assign(socket, sent?: true)}

      {:error, :captcha} ->
        {:noreply,
         socket
         |> assign(:error, "Please complete the captcha.")
         |> push_event("captcha:reset", %{})}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-sm space-y-6">
        <h1 class="text-2xl font-bold text-center">Reset your password</h1>

        <%= if @sent? do %>
          <div class="alert alert-info text-sm">
            If an account exists for that email, a reset link is on its way.
            The link expires in 1 hour.
          </div>
          <p class="text-sm text-center text-base-content/60">
            <.link navigate={~p"/login"} class="link link-primary">Back to log in</.link>
          </p>
        <% else %>
          <p class="text-sm text-base-content/60 text-center">
            Enter your email and we'll send you a link to choose a new password.
          </p>
          <.form for={@form} id="forgot-password-form" phx-submit="submit" class="space-y-4">
            <.input field={@form[:email]} type="email" label="Email" required autocomplete="email" />
            <.captcha :if={@captcha} id="forgot-password-captcha" widget={@captcha} />
            <p :if={@error} id="forgot-password-error" class="text-sm text-error">{@error}</p>
            <button type="submit" class="btn btn-primary w-full" phx-disable-with="Sending…">
              Send reset link
            </button>
          </.form>
          <p class="text-sm text-center text-base-content/60">
            Remembered it? <.link navigate={~p"/login"} class="link link-primary">Log in</.link>
          </p>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
