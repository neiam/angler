defmodule AnglerWeb.LoginLive do
  @moduledoc """
  Login form. Credentials are checked live for instant feedback, then the
  form is submitted natively (`phx-trigger-action`) to `SessionController`,
  which sets the session cookie — a LiveView socket can't write cookies, so
  the cookie-setting step has to be a real HTTP POST.

  With the captcha active on `:login`, the widget token is verified here
  before the credentials are checked, and the native POST carries a signed
  `captcha_pass` (`SessionController.captcha_pass/1`) in its place.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.AntiSpamComponents

  alias Angler.Captcha
  alias AnglerWeb.LoginThrottle
  alias AnglerWeb.Plugs.RemoteIp
  alias AnglerWeb.SessionController

  @impl true
  def mount(params, _session, socket) do
    if socket.assigns.current_user do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      # The live check reports whether credentials are right, so it is
      # throttled like the form POST — keyed on the same client IP.
      ip = if connected?(socket), do: RemoteIp.from_socket(socket)

      {:ok,
       socket
       |> assign(:client_ip, ip)
       |> assign(:page_title, "Log in")
       |> assign(:next, sanitize_next(params["next"]))
       |> assign(:error, nil)
       |> assign(:trigger_submit, false)
       |> assign(:captcha, Captcha.active_on?(:login) && Captcha.widget())
       |> assign(:captcha_pass, nil)
       |> assign(:form, to_form(%{"username" => "", "password" => ""}))}
    end
  end

  @impl true
  def handle_event("submit", %{"username" => handle, "password" => password} = params, socket) do
    if Captcha.check(:login, params, ip_string(socket.assigns.client_ip)) == :ok do
      authenticate(socket, handle, password, params)
    else
      {:noreply,
       socket
       |> assign(error: "Please complete the captcha.", form: to_form(params))
       |> push_event("captcha:reset", %{})}
    end
  end

  defp authenticate(socket, handle, password, params) do
    limit_key = LoginThrottle.key(socket.assigns.client_ip, handle)

    case LoginThrottle.authenticate(limit_key, handle, password) do
      {:ok, _user} ->
        pass = if socket.assigns.captcha, do: SessionController.captcha_pass(handle)
        {:noreply, assign(socket, trigger_submit: true, error: nil, captcha_pass: pass)}

      :error ->
        {:noreply,
         socket
         |> assign(error: "Invalid credentials.", form: to_form(params))
         |> push_event("captcha:reset", %{})}

      :rate_limited ->
        {:noreply,
         socket
         |> assign(
           error: "Too many failed attempts. Try again in a few minutes.",
           form: to_form(params)
         )
         |> push_event("captcha:reset", %{})}
    end
  end

  defp ip_string(nil), do: nil
  defp ip_string(ip), do: ip |> :inet.ntoa() |> to_string()

  defp sanitize_next(<<"/", _::binary>> = path), do: path
  defp sanitize_next(_), do: "/"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-sm space-y-6">
        <h1 class="text-2xl font-bold text-center">Log in</h1>

        <.form
          for={@form}
          id="login-form"
          action={~p"/session/login"}
          method="post"
          phx-submit="submit"
          phx-trigger-action={@trigger_submit}
          class="space-y-4"
        >
          <input type="hidden" name="next" value={@next} />
          <.input
            :if={@captcha_pass}
            type="hidden"
            id="login-captcha-pass"
            name="captcha_pass"
            value={@captcha_pass}
          />

          <.input field={@form[:username]} label="Username or email" required autocomplete="username" />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            required
            autocomplete="current-password"
          />

          <.captcha :if={@captcha} id="login-captcha" widget={@captcha} />

          <p :if={@error} id="login-error" class="text-sm text-error">{@error}</p>

          <button type="submit" class="btn btn-primary w-full" phx-disable-with="Signing in…">
            Log in
          </button>
        </.form>

        <p class="text-sm text-center">
          <.link navigate={~p"/forgot-password"} class="link link-hover text-base-content/60">
            Forgot your password?
          </.link>
        </p>

        <p class="text-sm text-center text-base-content/60">
          No account? <.link navigate={~p"/register"} class="link link-primary">Register</.link>
        </p>
      </div>
    </Layouts.app>
    """
  end
end
