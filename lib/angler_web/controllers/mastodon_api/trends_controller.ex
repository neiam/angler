defmodule AnglerWeb.MastodonAPI.TrendsController do
  @moduledoc """
    * GET /api/v1/trends/tags
    * GET /api/v1/trends/statuses
    * GET /api/v1/trends/links
  """

  use AnglerWeb, :controller

  alias Angler.Trends
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.Plugs.BearerAuth

  def tags(conn, params) do
    limit = parse_limit(params["limit"], 10, 20)

    body =
      Trends.tags(limit)
      |> Enum.map(fn %{tag: t, uses: uses, accounts: accounts} ->
        today = Date.utc_today() |> Date.to_iso8601()

        %{
          "name" => t.name,
          "url" => AnglerWeb.Endpoint.url() <> "/tags/" <> t.name,
          "history" => [
            %{
              "day" => today,
              "uses" => Integer.to_string(uses),
              "accounts" => Integer.to_string(accounts)
            }
          ]
        }
      end)

    json(conn, body)
  end

  def statuses(conn, params) do
    limit = parse_limit(params["limit"], 20, 40)

    viewer_id =
      case BearerAuth.current_scope(conn) do
        %{profile: %{id: pid}} -> pid
        _ -> nil
      end

    json(conn, Trends.statuses(limit, only_media: true) |> StatusJSON.render_many(viewer_id))
  end

  def links(conn, _params) do
    json(conn, [])
  end

  ## GET /trends — Pixelfed unified trends shape
  ##
  ## Pixelfed serves a flat empty array here; the per-kind endpoints
  ## (`/trends/tags|statuses|links`) are the canonical ones clients use.
  def unified(conn, _params), do: json(conn, [])

  defp parse_limit(nil, default, _max), do: default

  defp parse_limit(s, default, max) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n |> max(1) |> min(max)
      _ -> default
    end
  end

  defp parse_limit(_, default, _), do: default
end
