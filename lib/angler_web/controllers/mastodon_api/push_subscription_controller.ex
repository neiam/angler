defmodule AnglerWeb.MastodonAPI.PushSubscriptionController do
  @moduledoc """
    * POST   /api/v1/push/subscription   — register / replace
    * GET    /api/v1/push/subscription   — fetch current
    * PUT    /api/v1/push/subscription   — update alerts/policy
    * DELETE /api/v1/push/subscription   — unsubscribe

  We persist the subscription so a future WebPush delivery worker can pick
  it up — there is no actual push delivery yet.
  """

  use AnglerWeb, :controller

  alias Angler.Push
  alias Angler.Push.Subscription
  alias AnglerWeb.Plugs.BearerAuth

  def show(conn, _params) do
    %{token: token} = BearerAuth.current_scope(conn)

    case Push.get(token) do
      nil -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
      sub -> json(conn, render_sub(sub))
    end
  end

  def create(conn, params) do
    %{token: token} = BearerAuth.current_scope(conn)

    case Push.subscribe(token, params) do
      {:ok, sub} -> json(conn, render_sub(sub))
      {:error, cs} -> validation_error(conn, cs)
    end
  end

  def update(conn, params) do
    %{token: token} = BearerAuth.current_scope(conn)

    case Push.update_alerts(token, params) do
      {:ok, sub} ->
        json(conn, render_sub(sub))

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})

      {:error, cs} ->
        validation_error(conn, cs)
    end
  end

  def delete(conn, _params) do
    %{token: token} = BearerAuth.current_scope(conn)
    :ok = Push.unsubscribe(token)
    json(conn, %{})
  end

  defp render_sub(%Subscription{} = sub) do
    %{
      "id" => Integer.to_string(sub.id),
      "endpoint" => sub.endpoint,
      "alerts" =>
        ~w(mention favourite reblog follow follow_request poll status update)
        |> Map.new(fn k -> {k, Map.get(sub.alerts, k, false)} end),
      "policy" => sub.policy,
      "server_key" => Application.get_env(:angler, :push_vapid_public_key)
    }
  end

  defp validation_error(conn, cs) do
    errors =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", to_string(v))
        end)
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => "Validation failed", "errors" => errors})
  end
end
