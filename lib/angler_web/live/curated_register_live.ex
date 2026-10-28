defmodule AnglerWeb.CuratedRegisterLive do
  @moduledoc """
  Curated registration application form at `/auth/sign_up` (upstream
  `CuratedRegisterController::proceed` and `auth/curated-register/index`).

    1. Age gate: the applicant enters their date of birth, checked against
       `Angler.Instance.min_registration_age/0` and never stored. Upstream
       checks it in the browser and enforces an `age_verified` flag; here the
       server does the arithmetic.
    2. The application: username, email, password, reason to join and the
       rules agreement, guarded by the honeypot and (when active on
       `:curated_register`) the captcha.
    3. "Check your email" — `Angler.CuratedRegistrations.submit/2` sent the
       confirmation link.

  Only reachable while `Angler.Instance.curated_registration?/0` holds.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.AntiSpamComponents

  alias Angler.Captcha
  alias Angler.CuratedRegistrations
  alias Angler.CuratedRegistrations.CuratedRegister
  alias Angler.Instance
  alias AnglerWeb.Honeypot
  alias AnglerWeb.Plugs.RemoteIp

  @impl true
  def mount(_params, _session, socket) do
    cond do
      socket.assigns.current_user ->
        {:ok, push_navigate(socket, to: ~p"/")}

      not Instance.curated_registration?() ->
        to = if Instance.open_registration?(), do: ~p"/register", else: ~p"/"
        {:ok, push_navigate(socket, to: to)}

      true ->
        {:ok,
         socket
         |> assign(:page_title, "Apply for an account")
         |> assign(:client_ip, client_ip(socket))
         |> assign(:step, :age)
         |> assign(:error, nil)
         |> assign(:min_age, Instance.min_registration_age())
         |> assign(:age_form, to_form(%{"birthdate" => ""}, as: :age))
         |> assign(:captcha, Captcha.active_on?(:curated_register) && Captcha.widget())}
    end
  end

  @impl true
  def handle_event("check_age", %{"age" => %{"birthdate" => birthdate}}, socket) do
    case age_from(birthdate) do
      {:ok, age} when age <= 5 or age >= 120 ->
        {:noreply, assign(socket, :error, "That birth date isn't valid.")}

      {:ok, age} when age < socket.assigns.min_age ->
        {:noreply,
         assign(
           socket,
           :error,
           "Sorry, you must be at least #{socket.assigns.min_age} years old to join this server."
         )}

      {:ok, _age} ->
        {:noreply,
         socket
         |> assign(:step, :form)
         |> assign(:error, nil)
         |> assign(:honeypot, Honeypot.new())
         |> assign(:form, to_form(CuratedRegister.submit_changeset(%{})))}

      :error ->
        {:noreply, assign(socket, :error, "Enter your date of birth.")}
    end
  end

  def handle_event("apply", %{"curated_register" => attrs} = params, socket) do
    cond do
      Honeypot.spam?(socket.assigns.honeypot, params) ->
        {:noreply, assign(socket, step: :sent, email: attrs["email"])}

      Captcha.check(:curated_register, params) != :ok ->
        {:noreply,
         socket
         |> assign(:error, "Please complete the captcha.")
         |> push_event("captcha:reset", %{})}

      true ->
        case CuratedRegistrations.submit(attrs, socket.assigns.client_ip) do
          {:ok, register} ->
            {:noreply, assign(socket, step: :sent, email: register.email, error: nil)}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(:error, nil)
             |> assign(:form, to_form(changeset, action: :insert))
             |> push_event("captcha:reset", %{})}
        end
    end
  end

  defp client_ip(socket) do
    with true <- connected?(socket),
         ip when is_tuple(ip) <- RemoteIp.from_socket(socket) do
      ip |> :inet.ntoa() |> to_string()
    else
      _ -> nil
    end
  end

  defp age_from(birthdate) do
    with {:ok, dob} <- Date.from_iso8601(to_string(birthdate)) do
      today = Date.utc_today()
      had_birthday? = {today.month, today.day} >= {dob.month, dob.day}
      {:ok, today.year - dob.year - if(had_birthday?, do: 0, else: 1)}
    else
      _ -> :error
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-md space-y-6">
        <div class="text-center space-y-1">
          <h1 class="text-2xl font-bold">Apply for an account</h1>
          <p class="text-sm text-base-content/60">
            New accounts on this server are reviewed by the admin team.
          </p>
        </div>

        <%= case @step do %>
          <% :age -> %>
            <.form for={@age_form} id="curated-age-form" phx-submit="check_age" class="space-y-4">
              <p class="text-sm text-base-content/70">
                We ask for your date of birth only to confirm you are at least {@min_age}.
                It isn't stored.
              </p>
              <.input field={@age_form[:birthdate]} type="date" label="Date of birth" required />
              <p :if={@error} id="curated-error" class="text-sm text-error">{@error}</p>
              <button type="submit" class="btn btn-primary w-full">Continue</button>
            </.form>
          <% :form -> %>
            <.form for={@form} id="curated-apply-form" phx-submit="apply" class="space-y-4">
              <.input field={@form[:username]} label="Username" required autocomplete="username" />
              <.input field={@form[:email]} type="email" label="Email" required autocomplete="email" />
              <.input
                field={@form[:password]}
                type="password"
                label="Password"
                value=""
                required
                autocomplete="new-password"
              />
              <.input
                field={@form[:password_confirmation]}
                type="password"
                label="Confirm password"
                value=""
                required
                autocomplete="new-password"
              />
              <.input
                field={@form[:reason_to_join]}
                type="textarea"
                label="Why would you like to join?"
                rows="4"
                required
              />
              <.input
                field={@form[:agree]}
                type="checkbox"
                label="I agree to this server's rules and terms"
              />
              <.honeypot id="curated-hp" honeypot={@honeypot} />
              <.captcha :if={@captcha} id="curated-captcha" widget={@captcha} />
              <p :if={@error} id="curated-error" class="text-sm text-error">{@error}</p>
              <button type="submit" class="btn btn-primary w-full" phx-disable-with="Submitting…">
                Submit application
              </button>
            </.form>
          <% :sent -> %>
            <div id="curated-sent" class="alert alert-info text-sm">
              <.icon name="hero-envelope" class="size-5 shrink-0" />
              <span>
                Almost there! We emailed a confirmation link to <strong>{@email}</strong>.
                Your application is reviewed once your email is confirmed.
              </span>
            </div>
            <p class="text-sm text-center text-base-content/60">
              No email?
              <.link navigate={~p"/auth/sign_up/resend-confirmation"} class="link link-primary">
                Resend the confirmation link
              </.link>
            </p>
        <% end %>

        <p class="text-sm text-center text-base-content/60">
          Already have an account?
          <.link navigate={~p"/login"} class="link link-primary">Log in</.link>
        </p>
      </div>
    </Layouts.app>
    """
  end
end
