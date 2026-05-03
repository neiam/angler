defmodule AnglerWeb.HealthController do
  @moduledoc """
  Liveness/readiness probe.

  See `plans/instance/endpoints/get_health_check.md`.
  """

  use AnglerWeb, :controller

  alias Angler.Repo

  def show(conn, params) do
    case params["level"] do
      "ready" -> ready(conn)
      _ -> json(conn, %{status: "ok"})
    end
  end

  defp ready(conn) do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _} ->
        json(conn, %{status: "ok"})

      _ ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "error"})
    end
  rescue
    _ ->
      conn
      |> put_status(:service_unavailable)
      |> json(%{status: "error"})
  end
end
