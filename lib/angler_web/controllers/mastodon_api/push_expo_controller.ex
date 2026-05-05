defmodule AnglerWeb.MastodonAPI.PushExpoController do
  @moduledoc """
  Pixelfed-style Expo push subscription endpoints under `/api/v1.1/push/*`.

    * GET    /push/state    — current state
    * POST   /push/compare  — compare a token with the persisted one
    * POST   /push/update   — register / replace token + flags
    * POST   /push/disable  — clear subscription

  Each is gated by:
    * `:expo_push_enabled` config (404 when off)
    * an `X-PIXELFED-APP` request header (mobile signal; 404 when missing)

  Distinct from the Mastodon WebPush surface at `/api/v1/push/subscription`.
  """

  use AnglerWeb, :controller

  alias Angler.Profiles.Profile
  alias Angler.Push.Expo
  alias Angler.Repo
  alias AnglerWeb.Plugs.BearerAuth

  def state(conn, _params) do
    with :ok <- gate(conn) do
      %{user: user} = BearerAuth.current_scope(conn)
      json(conn, Expo.state(Repo.preload(user, :profile)))
    end
  end

  def compare(conn, params) do
    with :ok <- gate(conn),
         {:ok, candidate} <- require_valid_token(params, "expo_token") do
      %{user: user} = BearerAuth.current_scope(conn)
      user = Repo.preload(user, :profile)

      {match?, has_existing?} =
        case Expo.compare(user, candidate) do
          :match -> {true, true}
          :mismatch -> {false, true}
          :no_token -> {false, false}
        end

      json(conn, %{
        "version" => Expo.gateway_version(),
        "username" => username(user),
        "profile_id" => Integer.to_string(user.profile_id),
        "notify_enabled" => !!user.notify_enabled,
        "match" => match?,
        "has_existing" => has_existing?
      })
    else
      {:error, :missing_field} ->
        validation_error(conn, %{"expo_token" => ["is required"]})

      {:error, :invalid_token} ->
        validation_error(conn, %{"expo_token" => ["is invalid"]})

      other ->
        other
    end
  end

  def update(conn, params) do
    with :ok <- gate(conn),
         {:ok, _token} <- require_valid_token(params, "token") do
      %{user: user} = BearerAuth.current_scope(conn)

      case Expo.update(user, params) do
        {:ok, updated} ->
          json(conn, Expo.state(updated))

        {:error, :token_in_use} ->
          conn
          |> put_status(:bad_request)
          |> json(%{"error" => "Push token is already used by another account"})

        {:error, %Ecto.Changeset{} = cs} ->
          validation_error(conn, translate_errors(cs))
      end
    else
      {:error, :missing_field} ->
        validation_error(conn, %{"token" => ["is required"]})

      {:error, :invalid_token} ->
        validation_error(conn, %{"token" => ["is invalid"]})

      other ->
        other
    end
  end

  def disable(conn, _params) do
    with :ok <- gate(conn) do
      %{user: user} = BearerAuth.current_scope(conn)
      {:ok, updated} = Expo.disable(user)
      json(conn, Expo.state(updated))
    end
  end

  ## Internals

  # Returns :ok or a fully-rendered conn that short-circuits the `with`.
  defp gate(conn) do
    cond do
      not Expo.enabled?() -> not_found(conn)
      get_req_header(conn, "x-pixelfed-app") == [] -> not_found(conn)
      true -> :ok
    end
  end

  defp require_valid_token(params, key) do
    case params[key] do
      v when is_binary(v) and v != "" ->
        if Expo.valid_token?(v), do: {:ok, v}, else: {:error, :invalid_token}

      _ ->
        {:error, :missing_field}
    end
  end

  defp username(%{profile: %Profile{username: u}}) when is_binary(u), do: u

  defp username(%{profile_id: pid}) when is_integer(pid) do
    case Repo.get(Profile, pid) do
      %Profile{username: u} -> u
      _ -> ""
    end
  end

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{"error" => "Not found"})

  defp validation_error(conn, errors),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{"error" => "Validation failed", "errors" => errors})

  defp translate_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
  end
end
