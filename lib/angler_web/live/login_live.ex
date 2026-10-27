defmodule AnglerWeb.LoginLive do
  @moduledoc """
  Login form. Credentials are checked live for instant feedback, then the
  form is submitted natively (`phx-trigger-action`) to `SessionController`,
  which sets the session cookie — a LiveView socket can't write cookies, so
  the cookie-setting step has to be a real HTTP POST.
  """
  use AnglerWeb, :live_view

  alias AnglerWeb.LoginThrottle

  @impl true
  def mount(params, _session, socket) do
    if socket.assigns.current_user do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      # The live check reports whether credentials are right, so it is
      # throttled like the form POST — keyed on the same client IP.
      ip =
        case connected?(socket) && get_connect_info(socket, :peer_data) do
          %{address: address} -> address
          _ -> nil
        end

      {:ok,
       socket
       |> assign(:client_ip, ip)
       |> assign(:page_title, "Log in")
       |> assign(:next, sanitize_next(params["next"]))
       |> assign(:error, nil)
       |> assign(:trigger_submit, false)
       |> assign(:form, to_form(%{"username" => "", "password" => ""}))}
    end
  end

  @impl true
  def handle_event("submit", %{"username" => handle, "password" => password} = params, socket) do
    limit_key = LoginThrottle.key(socket.assigns.client_ip, handle)

    case LoginThrottle.authenticate(limit_key, handle, password) do
      {:ok, _user} ->
        {:noreply, assign(socket, trigger_submit: true, error: nil)}

      :error ->
        {:noreply, assign(socket, error: "Invalid credentials.", form: to_form(params))}

      :rate_limited ->
        {:noreply,
         assign(socket,
           error: "Too many failed attempts. Try again in a few minutes.",
           form: to_form(params)
         )}
    end
  end

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
          action={~p"/session/login"}
          method="post"
          phx-submit="submit"
          phx-trigger-action={@trigger_submit}
          class="space-y-4"
        >
          <input type="hidden" name="next" value={@next} />

          <.input field={@form[:username]} label="Username or email" required autocomplete="username" />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            required
            autocomplete="current-password"
          />

          <p :if={@error} class="text-sm text-error">{@error}</p>

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
