defmodule AnglerWeb.MastodonAPI.DiscoverController do
  @moduledoc """
  Pixelfed `discover/*` endpoints. Mounted under both `/api/v1/discover/posts`
  (Mastodon-shape) and `/api/v1.1/discover/...` (Pixelfed namespace).

    * GET /api/v1/discover/posts                — `{posts: [Status, ...]}`
    * GET /api/v1.1/discover/accounts/popular   — `[Account, ...]`
    * GET /api/v1.1/discover/posts/trending     — `[Status, ...]` (range=daily|monthly|yearly)
    * GET /api/v1.1/discover/posts/hashtags     — `[%{id, total, name, hashtag, url}, ...]`
    * GET /api/v1.1/discover/posts/network/trending — `[Status, ...]` from remote
      (federated) authors. The cross-instance counterpart to `trending_posts`,
      which covers instance-local trending.
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

  ## /api/v1.2/discover/accounts/popular
  #
  # Paged with an opaque `cursor` (the last row's followers_count + id) in
  # the Link header, like upstream.
  def accounts_popular_v2(conn, params) do
    viewer_id = viewer_id(conn)
    limit = params["limit"] |> to_int(16) |> min(40) |> max(1)
    profiles = Discover.accounts_popular_page(viewer_id, limit, decode_cursor(params["cursor"]))

    conn =
      case List.last(profiles) do
        %{} = last when length(profiles) == limit ->
          cursor = Base.url_encode64("#{last.followers_count}:#{last.id}", padding: false)
          query = URI.encode_query(%{"limit" => limit, "cursor" => cursor})
          next = AnglerWeb.Endpoint.url() <> conn.request_path <> "?" <> query
          put_resp_header(conn, "link", ~s(<#{next}>; rel="next"))

        _ ->
          conn
      end

    json(conn, Enum.map(profiles, &Account.render/1))
  end

  defp decode_cursor(c) when is_binary(c) do
    with {:ok, raw} <- Base.url_decode64(c, padding: false),
         [count, id] <- String.split(raw, ":"),
         {count, ""} <- Integer.parse(count),
         {id, ""} <- Integer.parse(id) do
      {count, id}
    else
      _ -> nil
    end
  end

  defp decode_cursor(_), do: nil

  defp to_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp to_int(_, default), do: default

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

  def network_trending(conn, _params) do
    viewer_id = viewer_id(conn)
    statuses = Discover.network_trending(viewer_id)
    json(conn, StatusJSON.render_many(statuses, viewer_id))
  end

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
