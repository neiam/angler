defmodule AnglerWeb.MastodonAPI.SearchController do
  @moduledoc """
  GET /api/v2/search?q=&type=&limit=&account_id=&following=&resolve=

  Returns:

      { "accounts": [Account, ...],
        "statuses": [Status, ...],
        "hashtags": [Tag, ...] }

  When `type` is specified, only that bucket is populated. The rest are
  empty arrays so clients don't have to special-case.

  The actual query logic lives in `Angler.Search`, shared with the web
  frontend (`AnglerWeb.SearchLive` and the navbar type-ahead). This controller
  only handles the `type` filtering and Mastodon JSON shaping.
  """

  use AnglerWeb, :controller

  alias Angler.Search
  alias AnglerWeb.Endpoint
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.Plugs.BearerAuth

  @default_limit 20

  def search(conn, params) do
    q = String.trim(params["q"] || "")

    if q == "" do
      json(conn, %{"accounts" => [], "statuses" => [], "hashtags" => []})
    else
      type = params["type"]
      limit = parse_limit(params["limit"])

      viewer_id =
        case BearerAuth.current_scope(conn) do
          %{profile: %{id: pid}} -> pid
          _ -> nil
        end

      body = %{
        "accounts" => if(type in [nil, "accounts"], do: search_accounts(q, limit), else: []),
        "statuses" =>
          if(type in [nil, "statuses"], do: search_statuses(q, viewer_id, limit), else: []),
        "hashtags" => if(type in [nil, "hashtags"], do: search_hashtags(q, limit), else: [])
      }

      json(conn, body)
    end
  end

  defp search_accounts(q, limit) do
    Search.accounts(q, limit: limit) |> Enum.map(&Account.render/1)
  end

  defp search_hashtags(q, limit) do
    Search.hashtags(q, limit: limit)
    |> Enum.map(fn h ->
      %{
        "name" => h.name,
        "url" => Endpoint.url() <> "/tags/" <> h.name,
        "history" => []
      }
    end)
  end

  defp search_statuses(q, viewer_id, limit) do
    Search.statuses(q, viewer_id, limit: limit) |> StatusJSON.render_many(viewer_id)
  end

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> Search.clamp_limit(n)
      _ -> @default_limit
    end
  end

  defp parse_limit(_), do: @default_limit
end
