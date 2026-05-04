defmodule AnglerWeb.Admin.ReportController do
  @moduledoc """
    * GET   /api/v1/admin/reports
    * GET   /api/v1/admin/reports/:id
    * POST  /api/v1/admin/reports/:id/assign_to_self
    * POST  /api/v1/admin/reports/:id/unassign
    * POST  /api/v1/admin/reports/:id/resolve
    * POST  /api/v1/admin/reports/:id/reopen
  """

  use AnglerWeb, :controller

  alias Angler.Admin
  alias Angler.Profiles
  alias Angler.Reports.Report
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.Plugs.BearerAuth

  def index(conn, params) do
    opts = []

    opts =
      case params["resolved"] do
        v when v in ["true", true] -> Keyword.put(opts, :resolved, true)
        v when v in ["false", false] -> Keyword.put(opts, :resolved, false)
        _ -> opts
      end

    opts =
      case parse_id(params["account_id"]) do
        {:ok, id} -> Keyword.put(opts, :account_id, id)
        _ -> opts
      end

    json(conn, Enum.map(Admin.list_reports(opts), &render_report/1))
  end

  def show(conn, %{"id" => id}) do
    with {:ok, int_id} <- parse_id(id),
         %Report{} = report <- Admin.get_report(int_id) do
      json(conn, render_report(report))
    else
      _ -> not_found(conn)
    end
  end

  def assign_to_self(conn, %{"id" => id}) do
    %{profile: moderator} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %Report{} = report <- Admin.get_report(int_id) do
      {:ok, updated} = Admin.assign(report, moderator)
      json(conn, render_report(updated))
    else
      _ -> not_found(conn)
    end
  end

  def unassign(conn, %{"id" => id}) do
    with {:ok, int_id} <- parse_id(id),
         %Report{} = report <- Admin.get_report(int_id) do
      {:ok, updated} = Admin.assign(report, nil)
      json(conn, render_report(updated))
    else
      _ -> not_found(conn)
    end
  end

  def resolve(conn, %{"id" => id}) do
    %{profile: moderator} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %Report{} = report <- Admin.get_report(int_id) do
      {:ok, updated} = Admin.resolve(report, moderator)
      json(conn, render_report(updated))
    else
      _ -> not_found(conn)
    end
  end

  def reopen(conn, %{"id" => id}) do
    with {:ok, int_id} <- parse_id(id),
         %Report{} = report <- Admin.get_report(int_id) do
      {:ok, updated} = Admin.reopen(report)
      json(conn, render_report(updated))
    else
      _ -> not_found(conn)
    end
  end

  ## Internals

  defp render_report(%Report{} = r) do
    %{
      "id" => Integer.to_string(r.id),
      "action_taken" => r.action_taken,
      "action_taken_at" => format_ts(r.action_taken_at),
      "category" => map_category(r.type),
      "comment" => r.moderator_comment || "",
      "forwarded" => false,
      "created_at" => format_ts(r.inserted_at),
      "updated_at" => format_ts(r.updated_at),
      "account" => render_profile(r.profile_id),
      "target_account" => render_profile(r.reported_profile_id),
      "assigned_account" => render_profile(r.assigned_account_id),
      "action_taken_by_account" => render_profile(r.action_taken_by_account_id),
      "statuses" => [],
      "rules" => []
    }
  end

  defp render_profile(nil), do: nil

  defp render_profile(id) do
    case Profiles.get_profile(id) do
      nil -> nil
      profile -> Account.render(profile)
    end
  end

  defp map_category("spam"), do: "spam"
  defp map_category("abusive"), do: "violation"
  defp map_category("violence"), do: "violation"
  defp map_category("underage"), do: "violation"
  defp map_category(_), do: "other"

  defp format_ts(nil), do: nil
  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_id(nil), do: :error

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
end
