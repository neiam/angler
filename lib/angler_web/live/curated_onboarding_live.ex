defmodule AnglerWeb.CuratedOnboardingLive do
  @moduledoc """
  The applicant's follow-up pages for curated registration, reached from
  the emails `Angler.CuratedRegistrations` sends (upstream
  `CuratedRegisterController` confirm / resend / concierge actions):

    * `:confirm` — `/auth/sign_up/confirm?sid=&code=` confirms the email.
    * `:resend` — `/auth/sign_up/resend-confirmation` re-sends that link.
    * `:concierge` — `/auth/sign_up/concierge?sid=&id=&code=` answers an
      admin's request for more details.

  Like upstream, these stay reachable after curated registration is
  switched off, so in-flight applications can finish. Each submit is
  captcha-guarded when the captcha is active on `:curated_register`.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.AntiSpamComponents

  alias Angler.Captcha
  alias Angler.CuratedRegistrations

  @impl true
  def mount(params, _session, socket) do
    if socket.assigns.current_user do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:error, nil)
       |> assign(:done, false)
       |> assign(:captcha, Captcha.active_on?(:curated_register) && Captcha.widget())
       |> init(socket.assigns.live_action, params)}
    end
  end

  defp init(socket, :confirm, params) do
    socket
    |> assign(:page_title, "Confirm your email")
    |> assign(:form, to_form(%{"sid" => params["sid"], "code" => params["code"]}, as: :confirm))
  end

  defp init(socket, :resend, _params) do
    socket
    |> assign(:page_title, "Resend confirmation")
    |> assign(:form, to_form(%{"email" => ""}, as: :resend))
  end

  defp init(socket, :concierge, params) do
    request = CuratedRegistrations.get_request(params["sid"], params["id"], params["code"])

    socket
    |> assign(:page_title, "Your application")
    |> assign(:request, request)
    |> assign(:form, to_form(%{"email" => "", "response" => ""}, as: :concierge))
  end

  @impl true
  def handle_event("confirm", %{"confirm" => %{"sid" => sid, "code" => code}} = params, socket) do
    with :ok <- Captcha.check(:curated_register, params),
         {:ok, _} <- CuratedRegistrations.confirm_email(sid, code) do
      {:noreply, assign(socket, done: true, error: nil)}
    else
      {:error, :captcha} -> captcha_failed(socket)
      {:error, :invalid} -> {:noreply, assign(socket, :error, "This link is invalid or expired.")}
    end
  end

  def handle_event("resend", %{"resend" => %{"email" => email}} = params, socket) do
    with :ok <- Captcha.check(:curated_register, params),
         :ok <- CuratedRegistrations.resend_confirmation(email) do
      {:noreply, assign(socket, done: true, error: nil)}
    else
      {:error, :captcha} ->
        captcha_failed(socket)

      {:error, :not_found} ->
        {:noreply, assign(socket, :error, "No unconfirmed application uses that email.")}

      {:error, :too_soon} ->
        {:noreply, assign(socket, :error, "You can only resend the link once every 12 hours.")}

      {:error, :too_many} ->
        {:noreply,
         assign(
           socket,
           :error,
           "You have resent the link too many times. Please contact the admin team."
         )}
    end
  end

  def handle_event("respond", %{"concierge" => attrs} = params, socket) do
    with :ok <- Captcha.check(:curated_register, params),
         {:ok, {register, activity}} <- socket.assigns.request,
         {:ok, _} <-
           CuratedRegistrations.respond(register, activity, attrs["email"], attrs["response"]) do
      {:noreply, assign(socket, done: true, error: nil)}
    else
      {:error, :captcha} -> captcha_failed(socket)
      {:error, :email_mismatch} -> error(socket, "That isn't the email you applied with.")
      {:error, :too_short} -> error(socket, "Your response is too short.")
      {:error, :too_long} -> error(socket, "Keep your response under 1000 characters.")
      {:error, :invalid} -> error(socket, "This link is invalid or was already answered.")
    end
  end

  defp error(socket, message),
    do: {:noreply, socket |> assign(:error, message) |> push_event("captcha:reset", %{})}

  defp captcha_failed(socket), do: error(socket, "Please complete the captcha.")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-md space-y-6">
        <h1 class="text-2xl font-bold text-center">{@page_title}</h1>
        {render_action(assigns)}
      </div>
    </Layouts.app>
    """
  end

  defp render_action(%{live_action: :confirm, done: true} = assigns) do
    ~H"""
    <div id="curated-confirmed" class="alert alert-success text-sm">
      <.icon name="hero-check-circle" class="size-5 shrink-0" />
      <span>
        Thanks, your email is confirmed. An admin will review your application and
        email you once it's decided.
      </span>
    </div>
    """
  end

  defp render_action(%{live_action: :confirm} = assigns) do
    ~H"""
    <.form for={@form} id="curated-confirm-form" phx-submit="confirm" class="space-y-4">
      <p class="text-sm text-base-content/70 text-center">
        Confirm your email address to send your application for review.
      </p>
      <.input field={@form[:sid]} type="hidden" />
      <.input field={@form[:code]} type="hidden" />
      <.captcha :if={@captcha} id="curated-confirm-captcha" widget={@captcha} />
      <p :if={@error} id="curated-error" class="text-sm text-error text-center">{@error}</p>
      <button type="submit" class="btn btn-primary w-full" phx-disable-with="Confirming…">
        Confirm my email
      </button>
    </.form>
    """
  end

  defp render_action(%{live_action: :resend, done: true} = assigns) do
    ~H"""
    <div id="curated-resent" class="alert alert-info text-sm">
      <.icon name="hero-envelope" class="size-5 shrink-0" />
      <span>We sent a new confirmation link. It expires in 7 days.</span>
    </div>
    """
  end

  defp render_action(%{live_action: :resend} = assigns) do
    ~H"""
    <.form for={@form} id="curated-resend-form" phx-submit="resend" class="space-y-4">
      <.input field={@form[:email]} type="email" label="Email you applied with" required />
      <.captcha :if={@captcha} id="curated-resend-captcha" widget={@captcha} />
      <p :if={@error} id="curated-error" class="text-sm text-error">{@error}</p>
      <button type="submit" class="btn btn-primary w-full" phx-disable-with="Sending…">
        Resend confirmation link
      </button>
    </.form>
    """
  end

  defp render_action(%{live_action: :concierge, done: true} = assigns) do
    ~H"""
    <div id="curated-response-sent" class="alert alert-success text-sm">
      <.icon name="hero-check-circle" class="size-5 shrink-0" />
      <span>Thanks! Your response was sent to the admin team.</span>
    </div>
    """
  end

  defp render_action(%{live_action: :concierge, request: {:error, _}} = assigns) do
    ~H"""
    <div id="curated-request-invalid" class="alert alert-warning text-sm">
      <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
      <span>This link is invalid or was already answered.</span>
    </div>
    """
  end

  defp render_action(%{live_action: :concierge, request: {:ok, {_register, activity}}} = assigns) do
    assigns = assign(assigns, :activity, activity)

    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body p-4 space-y-1">
        <div class="text-xs uppercase tracking-wide text-base-content/60">
          Message from the admin team
        </div>
        <p id="curated-admin-message" class="whitespace-pre-wrap">{@activity.message}</p>
      </div>
    </div>
    <.form for={@form} id="curated-concierge-form" phx-submit="respond" class="space-y-4">
      <.input field={@form[:email]} type="email" label="Email you applied with" required />
      <.input field={@form[:response]} type="textarea" label="Your response" rows="5" required />
      <.captcha :if={@captcha} id="curated-concierge-captcha" widget={@captcha} />
      <p :if={@error} id="curated-error" class="text-sm text-error">{@error}</p>
      <button type="submit" class="btn btn-primary w-full" phx-disable-with="Sending…">
        Send response
      </button>
    </.form>
    """
  end
end
