defmodule AnglerWeb.Admin.AnnouncementController do
  @moduledoc """
    * GET    /api/v1/admin/announcements
    * POST   /api/v1/admin/announcements
    * PUT    /api/v1/admin/announcements/:id
    * DELETE /api/v1/admin/announcements/:id
  """

  use AnglerWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Angler.Announcements
  alias Angler.Announcements.Announcement
  alias Angler.Repo

  def index(conn, _params) do
    rows =
      Repo.all(
        from a in Announcement,
          order_by: [desc: a.id],
          limit: 200
      )

    json(conn, Enum.map(rows, &render_one/1))
  end

  def create(conn, params) do
    case Announcements.create(params) do
      {:ok, ann} -> json(conn, render_one(ann))
      {:error, cs} -> validation_error(conn, cs)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, int_id} <- parse_id(id),
         %Announcement{} = ann <- Repo.get(Announcement, int_id),
         {:ok, updated} <- ann |> Announcement.changeset(params) |> Repo.update() do
      json(conn, render_one(updated))
    else
      {:error, cs} -> validation_error(conn, cs)
      _ -> not_found(conn)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, int_id} <- parse_id(id),
         %Announcement{} = ann <- Repo.get(Announcement, int_id) do
      Repo.delete!(ann)
      json(conn, %{})
    else
      _ -> not_found(conn)
    end
  end

  defp render_one(%Announcement{} = a) do
    %{
      "id" => Integer.to_string(a.id),
      "text" => a.text,
      "published" => a.published,
      "all_day" => a.all_day,
      "starts_at" => format_ts(a.starts_at),
      "ends_at" => format_ts(a.ends_at),
      "published_at" => format_ts(a.published_at),
      "created_at" => format_ts(a.inserted_at),
      "updated_at" => format_ts(a.updated_at)
    }
  end

  defp format_ts(nil), do: nil
  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}
  defp parse_id(_), do: :error

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})

  defp validation_error(conn, cs) do
    errors =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => "Validation failed", "errors" => errors})
  end
end
