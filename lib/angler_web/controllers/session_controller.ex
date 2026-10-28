defmodule AnglerWeb.SessionController do
  @moduledoc """
  Cookie-based login + logout for the OAuth consent flow (and any future
  in-app browser pages).

  Auth flow: `POST /session/login` with form fields `username` (or email)
  and `password`. On success, sets `session[:user_id]` and redirects to
  `next` (defaults to `/`). On failure, re-renders the login form with an
  error.

  When the captcha is active on `:login` (upstream
  `LoginController::validateLogin`), the POST must carry either a
  `captcha_pass` minted by the login LiveView after it verified the widget
  token, or a raw `captcha_token` to verify here. The plain form can't host
  the widget, so `new/2` sends people to the LiveView instead.
  """

  use AnglerWeb, :controller

  alias Angler.Accounts
  alias Angler.Accounts.TwoFactor
  alias Angler.Captcha

  @two_factor_token_salt "two-factor-complete"
  @two_factor_max_age 300
  @captcha_pass_salt "login-captcha-pass"
  @captcha_pass_max_age 120

  def new(conn, params) do
    next = params["next"] || "/"

    if Captcha.active_on?(:login) do
      redirect(conn, to: ~p"/login?#{[next: sanitize_next(next)]}")
    else
      render(conn, :new, error: nil, next: next, username: "")
    end
  end

  def create(conn, %{"username" => handle, "password" => password} = params) do
    next = sanitize_next(params["next"])

    if captcha_passed?(conn, handle, params) do
      do_create(conn, handle, password, next)
    else
      conn
      |> fetch_flash()
      |> put_flash(:error, "Please complete the captcha.")
      |> redirect(to: ~p"/login?#{[next: next]}")
    end
  end

  defp do_create(conn, handle, password, next) do
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

  @doc """
  A short-lived signed token saying the captcha was solved for `handle`.
  Widget tokens are single-use, so the login LiveView verifies the widget
  itself and hands this to the native form POST.
  """
  @spec captcha_pass(String.t()) :: String.t()
  def captcha_pass(handle) when is_binary(handle) do
    Phoenix.Token.sign(AnglerWeb.Endpoint, @captcha_pass_salt, String.downcase(handle))
  end

  defp captcha_passed?(conn, handle, params) do
    pass = params["captcha_pass"]

    cond do
      not Captcha.active_on?(:login) ->
        true

      is_binary(pass) and pass != "" ->
        expected = String.downcase(handle)

        match?(
          {:ok, ^expected},
          Phoenix.Token.verify(AnglerWeb.Endpoint, @captcha_pass_salt, pass,
            max_age: @captcha_pass_max_age
          )
        )

      true ->
        Captcha.verify(params[Captcha.response_field()], ip_string(conn.remote_ip))
    end
  end

  defp ip_string(nil), do: nil
  defp ip_string(ip), do: ip |> :inet.ntoa() |> to_string()

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
