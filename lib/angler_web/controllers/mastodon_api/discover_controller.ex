defmodule AnglerWeb.MastodonAPI.DiscoverController do
  @moduledoc """
  Pixelfed `discover/*` endpoints. Mounted under both `/api/v1/discover/posts`
  (Mastodon-shape) and `/api/v1.1/discover/...` (Pixelfed namespace).

    * GET /api/v1/discover/posts                — `{posts: [Status, ...]}`
    * GET /api/v1.1/discover/accounts/popular   — `[Account, ...]`
    * GET /api/v1.1/discover/posts/trending     — `[Status, ...]` (range=daily|monthly|yearly)
    * GET /api/v1.1/discover/posts/hashtags     — `[%{id, total, name, hashtag, url}, ...]`
    * GET /api/v1.1/discover/posts/network/trending — always `[]` (Beagle-equivalent
      cross-instance aggregator is upstream-only).
  """

  use AnglerWeb, :controller

  alias Angler.Discover
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.Plugs.BearerAuth

  ## /api/v1/discover/posts

  def for_you(conn, params) do
    viewer_id = viewer_id(conn)
    limit = parse_limit(params["limit"], 12, 40)
    statuses = Discover.for_you(viewer_id, limit)
    json(conn, %{"posts" => StatusJSON.render_many(statuses, viewer_id)})
  end

  ## /api/v1.1/discover/accounts/popular

  def accounts_popular(conn, _params) do
    viewer_id = viewer_id(conn)
    profiles = Discover.accounts_popular(viewer_id)
    json(conn, Enum.map(profiles, &Account.render/1))
  end

  ## /api/v1.1/discover/posts/trending

  def trending_posts(conn, params) do
    viewer_id = viewer_id(conn)

    range =
      case params["range"] do
        "daily" -> :daily
        "yearly" -> :yearly
        _ -> :monthly
      end

    statuses = Discover.trending_posts(viewer_id, range)
    json(conn, StatusJSON.render_many(statuses, viewer_id))
  end

  ## /api/v1.1/discover/posts/hashtags

  def trending_hashtags(conn, _params) do
    base = AnglerWeb.Endpoint.url()

    body =
      Discover.trending_hashtags()
      |> Enum.map(fn %{tag: t, total: total} ->
        %{
          "id" => Integer.to_string(t.id),
          "total" => total,
          "name" => "#" <> t.name,
          "hashtag" => t.name,
          "url" => base <> "/tags/" <> t.name
        }
      end)

    json(conn, body)
  end

  ## /api/v1.1/discover/posts/network/trending

  def network_trending(conn, _params), do: json(conn, [])

  ## Internals

  defp viewer_id(conn) do
    case BearerAuth.current_scope(conn) do
      %{profile: %{id: id}} -> id
      _ -> nil
    end
  end

  defp parse_limit(nil, default, _max), do: default

  defp parse_limit(s, default, max) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n |> max(1) |> min(max)
      _ -> default
    end
  end

  defp parse_limit(n, _default, max) when is_integer(n), do: n |> max(1) |> min(max)
  defp parse_limit(_, default, _max), do: default
end
