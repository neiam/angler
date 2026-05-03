defmodule AnglerWeb.SessionController do
  @moduledoc """
  Cookie-based login + logout for the OAuth consent flow (and any future
  in-app browser pages).

  Auth flow: `POST /session/login` with form fields `username` (or email)
  and `password`. On success, sets `session[:user_id]` and redirects to
  `next` (defaults to `/`). On failure, re-renders the login form with an
  error.
  """

  use AnglerWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Angler.Accounts
  alias Angler.Accounts.User

  def new(conn, params) do
    next = params["next"] || "/"
    render(conn, :new, error: nil, next: next, username: "")
  end

  def create(conn, %{"username" => handle, "password" => password} = params) do
    next = sanitize_next(params["next"])
    user = lookup(handle)

    cond do
      is_nil(user) ->
        _ = User.valid_password?(nil, password)
        render(conn, :new, error: "Invalid credentials.", next: next, username: handle)

      User.valid_password?(user, password) ->
        conn
        |> configure_session(renew: true)
        |> put_session(:user_id, user.id)
        |> redirect(to: next)

      true ->
        render(conn, :new, error: "Invalid credentials.", next: next, username: handle)
    end
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/")
  end

  defp lookup(handle) when is_binary(handle) do
    if String.contains?(handle, "@") do
      Accounts.get_by_email(handle)
    else
      case Angler.Profiles.get_local_by_username(handle) do
        %{id: pid} ->
          Angler.Repo.one(
            from u in Angler.Accounts.User, where: u.profile_id == ^pid and is_nil(u.status)
          )

        _ ->
          nil
      end
    end
  end

  defp lookup(_), do: nil

  # Avoid open-redirect: only allow same-origin paths.
  defp sanitize_next(nil), do: "/"
  defp sanitize_next(""), do: "/"
  defp sanitize_next(<<"/", _::binary>> = path), do: path
  defp sanitize_next(_), do: "/"
end
