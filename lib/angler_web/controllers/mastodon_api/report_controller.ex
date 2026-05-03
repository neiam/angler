defmodule AnglerWeb.MastodonAPI.ReportController do
  @moduledoc """
  POST /api/v1/reports — Mastodon-shape report intake.

  Accepts:

      account_id (required)         - target profile id
      status_ids[] (optional)       - ids of statuses to attach
      comment (optional)            - free-text reason
      forward (optional)            - bool, forward to remote instance
      category (optional)           - "spam" | "violation" | "other"
      rule_ids[] (optional)         - violated server rules

  Returns Mastodon-shape `Report` JSON.
  """

  use AnglerWeb, :controller

  alias Angler.Reports
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.Plugs.BearerAuth

  def create(conn, params) do
    %{user: user} = BearerAuth.current_scope(conn)

    pixelfed_attrs = %{
      "report_type" => map_category(params["category"], params["comment"]),
      "object_id" => params["account_id"],
      "object_type" => "user"
    }

    case Reports.submit(user, pixelfed_attrs) do
      {:ok, report} ->
        target = Angler.Profiles.get_profile(report.reported_profile_id)

        json(conn, %{
          "id" => Integer.to_string(report.id),
          "action_taken" => false,
          "action_taken_at" => nil,
          "category" => params["category"] || "other",
          "comment" => params["comment"] || "",
          "forwarded" => false,
          "created_at" => DateTime.to_iso8601(report.inserted_at),
          "status_ids" => List.wrap(params["status_ids"] || []),
          "rule_ids" => List.wrap(params["rule_ids"] || []),
          "target_account" => target && Account.render(target)
        })

      {:error, :duplicate} ->
        validation_error(conn, "already reported")

      {:error, :self_report} ->
        validation_error(conn, "cannot self-report")

      {:error, :invalid_object_id} ->
        conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})

      {:error, reason} ->
        validation_error(conn, to_string(reason))
    end
  end

  defp map_category("spam", _), do: "spam"
  defp map_category("violation", _), do: "abusive"
  defp map_category(_, comment) when is_binary(comment), do: "abusive"
  defp map_category(_, _), do: "spam"

  defp validation_error(conn, msg),
    do: conn |> put_status(:unprocessable_entity) |> json(%{"error" => msg})
end
