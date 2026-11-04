defmodule AnglerWeb.ResetPasswordLive do
  @moduledoc """
  Set a new password from an emailed magic link (`/reset-password/:token`).
  Invalid or expired tokens render a dead-end with a way to request a fresh
  one.
  """
  use AnglerWeb, :live_view

  alias Angler.Accounts

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Accounts.get_user_by_reset_token(token) do
      %Accounts.User{} = user ->
        {:ok,
         socket
         |> assign(:page_title, "Choose a new password")
         |> assign(:user, user)
         |> assign(:error, nil)
         |> assign(:form, to_form(%{"password" => "", "password_confirmation" => ""}))}

      _ ->
        {:ok,
         socket
         |> assign(:page_title, "Reset link invalid")
         |> assign(:user, nil)}
    end
  end

  @impl true
  def handle_event("reset", %{"password" => pw, "password_confirmation" => confirm}, socket) do
    if pw != confirm do
      {:noreply, assign(socket, error: "Passwords don't match.")}
    else
      case Accounts.reset_password(socket.assigns.user, %{password: pw}) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> put_flash(:info, "Your password was updated — please log in.")
           |> push_navigate(to: ~p"/login")}

        {:error, changeset} ->
          {:noreply, assign(socket, error: changeset_error(changeset))}
      end
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
      "" -> "Could not update the password. Check your details."
      msg -> msg
    end
  end

  @impl true
  def render(%{user: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-sm text-center py-12 space-y-2">
        <.icon name="hero-link-slash" class="size-6" />
        <h1 class="text-2xl font-bold">Reset link invalid</h1>
        <p class="text-base-content/60">This link is invalid or has expired.</p>
        <.link navigate={~p"/forgot-password"} class="btn btn-primary btn-sm mt-2">
          Request a new link
        </.link>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-sm space-y-6">
        <h1 class="text-2xl font-bold text-center">Choose a new password</h1>

        <.form for={@form} phx-submit="reset" class="space-y-4">
          <.input
            field={@form[:password]}
            type="password"
            label="New password"
            required
            autocomplete="new-password"
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label="Confirm new password"
            required
            autocomplete="new-password"
          />
          <p :if={@error} class="text-sm text-error">{@error}</p>
          <button type="submit" class="btn btn-primary w-full" phx-disable-with="Updating…">
            Update password
          </button>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
