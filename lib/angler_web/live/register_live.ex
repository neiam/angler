defmodule AnglerWeb.RegisterLive do
  @moduledoc """
  Web registration, mirroring the API onboarding flow and honoring the
  instance gates:

    * `open_registration?` false → the form is hidden behind a closed notice.
    * Step 1 emails a 6-digit verification code (`Angler.Auth.issue_code/1`).
    * Step 2 verifies the code and creates the account (`Accounts.register/1`).
    * `approval_required?` is surfaced in the success message.

  A LiveView socket can't set the session cookie, so on success we send the
  new user to `/login` rather than logging them in here.
  """
  use AnglerWeb, :live_view

  alias Angler.Accounts
  alias Angler.Auth
  alias Angler.Auth.Username
  alias Angler.Instance

  @email_re ~r/^[^\s@]+@[^\s@]+$/

  @impl true
  def mount(_params, _session, socket) do
    cond do
      socket.assigns.current_user ->
        {:ok, push_navigate(socket, to: ~p"/")}

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
         |> assign(:form, to_form(%{"email" => ""}))}
    end
  end

  @impl true
  def handle_event("request_code", %{"email" => email}, socket) do
    email = email |> to_string() |> String.trim() |> String.downcase()

    cond do
      not Regex.match?(@email_re, email) ->
        {:noreply, assign(socket, error: "Enter a valid email address.")}

      Accounts.get_by_email(email) ->
        {:noreply, assign(socket, error: "An account with that email already exists.")}

      true ->
        case Auth.issue_code(email) do
          {:ok, code, _register} ->
            _ = Auth.Workers.SendAppCodeEmail.enqueue(email, code)

            {:noreply,
             socket
             |> assign(:step, :details)
             |> assign(:email, email)
             |> assign(:error, nil)
             |> assign(
               :form,
               to_form(%{"code" => "", "username" => "", "password" => "", "name" => ""})
             )
             |> put_flash(:info, "We emailed a 6-digit code to #{email}.")}

          {:error, :too_many_attempts} ->
            {:noreply, assign(socket, error: "Too many attempts. Please try again later.")}

          {:error, _} ->
            {:noreply, assign(socket, error: "Could not start registration. Try again.")}
        end
    end
  end

  def handle_event("register", %{"code" => code, "username" => username} = params, socket) do
    email = socket.assigns.email
    password = params["password"] || ""
    name = blank_to_nil(params["name"])

    with :ok <- require_present(username, "Choose a username."),
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
      <div class="mx-auto max-w-sm text-center py-12 space-y-2">
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
          <.form for={@form} phx-submit="request_code" class="space-y-4">
            <.input field={@form[:email]} type="email" label="Email" required autocomplete="email" />
            <p :if={@error} class="text-sm text-error">{@error}</p>
            <button type="submit" class="btn btn-primary w-full" phx-disable-with="Sending…">
              Send verification code
            </button>
          </.form>
        <% else %>
          <.form for={@form} phx-submit="register" class="space-y-4">
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
            <p :if={@error} class="text-sm text-error">{@error}</p>
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
