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

  alias Angler.Accounts

  def new(conn, params) do
    next = params["next"] || "/"
    render(conn, :new, error: nil, next: next, username: "")
  end

  def create(conn, %{"username" => handle, "password" => password} = params) do
    next = sanitize_next(params["next"])

    case Accounts.authenticate(handle, password) do
      {:ok, user} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:user_id, user.id)
        |> redirect(to: next)

      :error ->
        render(conn, :new, error: "Invalid credentials.", next: next, username: handle)
    end
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/")
  end

  # Avoid open-redirect: only allow same-origin paths.
  defp sanitize_next(nil), do: "/"
  defp sanitize_next(""), do: "/"
  defp sanitize_next(<<"/", _::binary>> = path), do: path
  defp sanitize_next(_), do: "/"
end
