defmodule AnglerWeb.MastodonAPI.ScheduledStatusController do
  @moduledoc """
  Owner-scoped CRUD on scheduled statuses:

    * GET    /api/v1/scheduled_statuses
    * GET    /api/v1/scheduled_statuses/:id
    * PUT    /api/v1/scheduled_statuses/:id   — update `scheduled_at`
    * DELETE /api/v1/scheduled_statuses/:id
  """

  use AnglerWeb, :controller

  alias Angler.Statuses.Scheduling
  alias AnglerWeb.MastodonAPI.ScheduledStatus, as: ScheduledStatusJSON
  alias AnglerWeb.Plugs.BearerAuth

  def index(conn, _params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    json(conn, Scheduling.list(profile.id) |> ScheduledStatusJSON.render_many())
  end

  def show(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %_{} = row <- Scheduling.get(profile.id, int_id) do
      json(conn, ScheduledStatusJSON.render(row))
    else
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  def update(conn, %{"id" => id} = params) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %_{} = row <- Scheduling.get(profile.id, int_id),
         {:ok, updated} <-
           Scheduling.update_scheduled_at(row, params["scheduled_at"]) do
      json(conn, ScheduledStatusJSON.render(updated))
    else
      {:error, :too_soon} ->
        conn |> put_status(:unprocessable_entity) |> json(%{"error" => "scheduled_at too soon"})

      {:error, reason} when is_atom(reason) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => Atom.to_string(reason)})

      _ ->
        conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  def delete(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %_{} <- Scheduling.get(profile.id, int_id) do
      :ok = Scheduling.delete(profile.id, int_id)
      json(conn, %{})
    else
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}
  defp parse_id(_), do: :error
end
