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
  alias Angler.Accounts.TwoFactor

  @two_factor_token_salt "two-factor-complete"
  @two_factor_max_age 300

  def new(conn, params) do
    next = params["next"] || "/"
    render(conn, :new, error: nil, next: next, username: "")
  end

  def create(conn, %{"username" => handle, "password" => password} = params) do
    next = sanitize_next(params["next"])
    limit_key = AnglerWeb.LoginThrottle.key(conn, handle)

    case AnglerWeb.LoginThrottle.authenticate(limit_key, handle, password) do
      :rate_limited ->
        render(conn, :new,
          error: "Too many failed attempts. Try again in a few minutes.",
          next: next,
          username: handle
        )

      {:ok, user} ->
        if TwoFactor.any_factor?(user) do
          # Password OK but a second factor is required — stash a *pending*
          # login (not a real session) and send the user to the challenge.
          conn
          |> configure_session(renew: true)
          |> put_session(:two_factor_user_id, user.id)
          |> put_session(:two_factor_next, next)
          |> delete_session(:two_factor_passed_user_id)
          |> redirect(to: ~p"/login/two-factor")
        else
          login(conn, user, next)
        end

      :error ->
        render(conn, :new, error: "Invalid credentials.", next: next, username: handle)
    end
  end

  @doc """
  Finalize a login after the second factor is proven. Reached by:

    * the TOTP/recovery challenge LiveView, which redirects here with a signed
      `token` it minted via `two_factor_token/2` after verifying the code, or
    * the WebAuthn finish endpoint, which sets `:two_factor_passed_user_id` in
      the session and redirects here.

  Either proof must match the pending `:two_factor_user_id`, so neither a
  forged token nor a direct hit on this path can bypass the factor.
  """
  def complete_two_factor(conn, params) do
    pending = get_session(conn, :two_factor_user_id)

    cond do
      is_nil(pending) ->
        redirect(conn, to: ~p"/login")

      valid_token?(params["token"], pending) or
          get_session(conn, :two_factor_passed_user_id) == pending ->
        next = sanitize_next(get_session(conn, :two_factor_next))

        case Accounts.get_user(pending) do
          %{} = user -> login(conn, user, next)
          _ -> redirect(conn, to: ~p"/login")
        end

      true ->
        redirect(conn, to: ~p"/login/two-factor")
    end
  end

  @doc "A short-lived signed token binding a verified second factor to `user_id`."
  def two_factor_token(conn, user_id) do
    Phoenix.Token.sign(conn, @two_factor_token_salt, user_id)
  end

  defp valid_token?(nil, _pending), do: false

  defp valid_token?(token, pending) do
    case Phoenix.Token.verify(AnglerWeb.Endpoint, @two_factor_token_salt, token,
           max_age: @two_factor_max_age
         ) do
      {:ok, ^pending} -> true
      _ -> false
    end
  end

  defp login(conn, user, next) do
    conn
    |> configure_session(renew: true)
    |> put_session(:user_id, user.id)
    |> delete_session(:two_factor_user_id)
    |> delete_session(:two_factor_next)
    |> delete_session(:two_factor_passed_user_id)
    |> redirect(to: next)
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
