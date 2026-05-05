defmodule AnglerWeb.MastodonAPI.AdminInviteController do
  @moduledoc """
  Pre-registration validation for admin-issued signup invites.

    * POST /api/v1.1/auth/invite/admin/verify — invite code is valid
    * POST /api/v1.1/auth/invite/admin/uc     — username is available
    * POST /api/v1.1/auth/invite/admin/ec     — email is available

  All three are anonymous (no bearer auth) but rate-limited and require
  a valid `token` (the invite code). When the operator hasn't seeded any
  invites these are still safe to call — `token` lookups return 404.
  """

  use AnglerWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Angler.Accounts.User
  alias Angler.Invites
  alias Angler.Invites.AdminInvite
  alias Angler.Profiles.Profile
  alias Angler.Repo

  def verify(conn, params) do
    with {:ok, code} <- require_field(params, "token"),
         {:ok, %AdminInvite{} = invite} <- Invites.verify(code) do
      json(conn, %{
        "message" => invite.message,
        "max_uses" => invite.max_uses,
        "sev" => !!invite.skip_email_verification
      })
    else
      {:error, :missing_field} ->
        bad_request(conn, "token is required")

      {:error, :not_found} ->
        not_found(conn)

      {:error, :expired} ->
        bad_request(conn, "Invite has expired.")

      {:error, :exhausted} ->
        bad_request(conn, "Maximum invites reached.")
    end
  end

  def username_check(conn, params) do
    with {:ok, _code} <- valid_invite(params),
         {:ok, username} <- require_field(params, "username") do
      cond do
        not username_format_valid?(username) ->
          validation_error(conn, %{"username" => ["Username is invalid."]})

        username_taken?(username) ->
          validation_error(conn, %{"username" => ["Username has already been taken."]})

        true ->
          json(conn, %{})
      end
    else
      {:error, :missing_field} -> bad_request(conn, "Missing required field")
      {:error, :not_found} -> not_found(conn)
      {:error, :expired} -> bad_request(conn, "Invite has expired.")
      {:error, :exhausted} -> bad_request(conn, "Maximum invites reached.")
    end
  end

  def email_check(conn, params) do
    with {:ok, _code} <- valid_invite(params),
         {:ok, email} <- require_field(params, "email") do
      cond do
        not email_format_valid?(email) ->
          validation_error(conn, %{"email" => ["Email is invalid."]})

        email_taken?(email) ->
          validation_error(conn, %{"email" => ["Email has already been taken."]})

        true ->
          json(conn, %{})
      end
    else
      {:error, :missing_field} -> bad_request(conn, "Missing required field")
      {:error, :not_found} -> not_found(conn)
      {:error, :expired} -> bad_request(conn, "Invite has expired.")
      {:error, :exhausted} -> bad_request(conn, "Maximum invites reached.")
    end
  end

  ## Internals

  defp valid_invite(params) do
    with {:ok, code} <- require_field(params, "token"),
         {:ok, _invite} <- Invites.verify(code) do
      {:ok, code}
    end
  end

  defp require_field(params, key) do
    case params[key] do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, :missing_field}
    end
  end

  defp username_format_valid?(u) do
    Regex.match?(~r/^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,28}[A-Za-z0-9])?$/, u)
  end

  defp username_taken?(u) do
    down = String.downcase(u)

    Repo.exists?(
      from p in Profile,
        where: is_nil(p.domain) and fragment("lower(?)", p.username) == ^down
    )
  end

  defp email_format_valid?(email) do
    String.length(email) <= 254 and Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email)
  end

  defp email_taken?(email) do
    Repo.exists?(from u in User, where: u.email == ^String.downcase(email))
  end

  defp bad_request(conn, msg),
    do: conn |> put_status(:bad_request) |> json(%{"error" => msg})

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{"error" => "Not found"})

  defp validation_error(conn, errors),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{"error" => "Validation failed", "errors" => errors})
end
