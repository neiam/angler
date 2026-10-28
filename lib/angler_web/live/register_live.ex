defmodule AnglerWeb.RegisterLive do
  @moduledoc """
  Web registration, mirroring the API onboarding flow and honoring the
  instance gates:

    * `open_registration?` false → the form is hidden behind a closed notice,
      or, with curated registration on, forwards to the application form
      (upstream `fallback_on_closed_reg`).
    * Step 1 emails a 6-digit verification code (`Angler.Auth.issue_code/1`).
      It is guarded by the honeypot and, when active on `:register`, the
      captcha (upstream `RegisterController` + `ProtectAgainstSpam`).
    * Step 2 verifies the code and creates the account (`Accounts.register/1`).
      It requires upstream's "I am at least N years old" confirmation
      (`agecheck`).
    * `approval_required?` is surfaced in the success message.

  A LiveView socket can't set the session cookie, so on success we send the
  new user to `/login` rather than logging them in here.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.AntiSpamComponents

  alias Angler.Accounts
  alias Angler.Auth
  alias Angler.Auth.Username
  alias Angler.Captcha
  alias Angler.Instance
  alias AnglerWeb.Honeypot

  @email_re ~r/^[^\s@]+@[^\s@]+$/

  @impl true
  def mount(_params, _session, socket) do
    cond do
      socket.assigns.current_user ->
        {:ok, push_navigate(socket, to: ~p"/")}

      not Instance.open_registration?() and Instance.curated_registration?() ->
        {:ok, push_navigate(socket, to: ~p"/auth/sign_up")}

      not Instance.open_registration?() ->
        {:ok,
         socket
         |> assign(:page_title, "Register")
         |> assign(:step, :closed)
         |> assign(:error, nil)}

      true ->
        {:ok,
         socket
         |> assign(:page_title, "Register")
         |> assign(:step, :email)
         |> assign(:approval?, Instance.approval_required?())
         |> assign(:email, nil)
         |> assign(:error, nil)
         |> assign(:min_age, Instance.min_registration_age())
         |> assign(:honeypot, Honeypot.new())
         |> assign(:captcha, Captcha.active_on?(:register) && Captcha.widget())
         |> assign(:form, to_form(%{"email" => ""}))}
    end
  end

  @impl true
  def handle_event("request_code", %{"email" => email} = params, socket) do
    email = email |> to_string() |> String.trim() |> String.downcase()

    cond do
      Honeypot.spam?(socket.assigns.honeypot, params) ->
        {:noreply, to_details_step(socket, email)}

      not Regex.match?(@email_re, email) ->
        {:noreply, assign(socket, error: "Enter a valid email address.")}

      Accounts.get_by_email(email) ->
        {:noreply, assign(socket, error: "An account with that email already exists.")}

      Captcha.check(:register, params) != :ok ->
        {:noreply,
         socket
         |> assign(error: "Please complete the captcha.")
         |> push_event("captcha:reset", %{})}

      true ->
        case Auth.issue_code(email) do
          {:ok, code, _register} ->
            _ = Auth.Workers.SendAppCodeEmail.enqueue(email, code)
            {:noreply, to_details_step(socket, email)}

          {:error, :too_many_attempts} ->
            {:noreply,
             socket
             |> assign(error: "Too many attempts. Please try again later.")
             |> push_event("captcha:reset", %{})}

          {:error, _} ->
            {:noreply,
             socket
             |> assign(error: "Could not start registration. Try again.")
             |> push_event("captcha:reset", %{})}
        end
    end
  end

  def handle_event("register", %{"code" => code, "username" => username} = params, socket) do
    email = socket.assigns.email
    password = params["password"] || ""
    name = blank_to_nil(params["name"])

    with :ok <- require_age_check(params["agecheck"], socket.assigns.min_age),
         :ok <- require_present(username, "Choose a username."),
         :ok <- require_present(password, "Choose a password."),
         :ok <- validate_username(username),
         :ok <- ensure_username_available(username),
         :ok <- verify(email, code),
         {:ok, _result} <-
           Accounts.register(%{
             email: email,
             verify_code: code,
             username: username,
             password: password,
             name: name
           }) do
      Auth.consume!(email)

      {:noreply,
       socket
       |> put_flash(:info, success_message(socket))
       |> push_navigate(to: ~p"/login")}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, error: message)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, error: changeset_error(changeset))}

      {:error, reason} ->
        {:noreply, assign(socket, error: "Could not create the account (#{inspect(reason)}).")}
    end
  end

  # A tripped honeypot lands here too, so the bot sees the same next step.
  defp to_details_step(socket, email) do
    socket
    |> assign(:step, :details)
    |> assign(:email, email)
    |> assign(:error, nil)
    |> assign(
      :form,
      to_form(%{
        "code" => "",
        "username" => "",
        "password" => "",
        "name" => "",
        "agecheck" => "false"
      })
    )
    |> put_flash(:info, "We emailed a 6-digit code to #{email}.")
  end

  defp changeset_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
    |> case do
      "" -> "Could not create the account. Check your details."
      msg -> msg
    end
  end

  ## Step-2 validation helpers (return :ok | {:error, message})

  defp require_age_check("true", _min_age), do: :ok
  defp require_age_check(_, min_age), do: {:error, "You must be at least #{min_age} years old."}

  defp require_present(value, message) do
    if is_binary(value) and String.trim(value) != "", do: :ok, else: {:error, message}
  end

  defp validate_username(username) do
    case Username.validate(username) do
      :ok -> :ok
      _ -> {:error, "That username isn't allowed."}
    end
  end

  defp ensure_username_available(username) do
    if Accounts.username_available?(username), do: :ok, else: {:error, "That username is taken."}
  end

  defp verify(email, code) do
    case Auth.verify_code(email, code) do
      :ok -> :ok
      :error -> {:error, "That verification code is invalid or expired."}
    end
  end

  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank_to_nil(_), do: nil

  defp success_message(socket) do
    if socket.assigns.approval? do
      "Account created — it's pending operator approval. You can sign in once approved."
    else
      "Account created! Please log in."
    end
  end

  @impl true
  def render(%{step: :closed} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div id="register-closed" class="mx-auto max-w-sm text-center py-12 space-y-2">
        <.icon name="hero-lock-closed" class="size-6" />
        <h1 class="text-2xl font-bold">Registration is closed</h1>
        <p class="text-base-content/60">This instance isn't accepting new accounts right now.</p>
        <.link navigate={~p"/login"} class="btn btn-ghost btn-sm mt-2">Log in</.link>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-sm space-y-6">
        <h1 class="text-2xl font-bold text-center">Create an account</h1>

        <%= if @step == :email do %>
          <.form for={@form} id="register-email-form" phx-submit="request_code" class="space-y-4">
            <.input field={@form[:email]} type="email" label="Email" required autocomplete="email" />
            <.honeypot id="register-hp" honeypot={@honeypot} />
            <.captcha :if={@captcha} id="register-captcha" widget={@captcha} />
            <p :if={@error} id="register-error" class="text-sm text-error">{@error}</p>
            <button type="submit" class="btn btn-primary w-full" phx-disable-with="Sending…">
              Send verification code
            </button>
          </.form>
        <% else %>
          <.form for={@form} id="register-details-form" phx-submit="register" class="space-y-4">
            <p class="text-sm text-base-content/60">
              Enter the code we emailed to <span class="font-medium">{@email}</span>.
            </p>
            <.input field={@form[:code]} label="Verification code" required inputmode="numeric" />
            <.input field={@form[:username]} label="Username" required autocomplete="username" />
            <.input field={@form[:name]} label="Display name (optional)" />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              required
              autocomplete="new-password"
            />
            <.input
              field={@form[:agecheck]}
              type="checkbox"
              id="register-agecheck"
              label={"I am at least #{@min_age} years old"}
            />
            <p :if={@error} id="register-error" class="text-sm text-error">{@error}</p>
            <button type="submit" class="btn btn-primary w-full" phx-disable-with="Creating…">
              Create account
            </button>
          </.form>
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
