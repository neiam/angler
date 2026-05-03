defmodule AnglerWeb.MastodonAPI.AccountListsController do
  @moduledoc """
  GET /api/v1/favourites — statuses the authed account has liked.
  GET /api/v1/bookmarks — statuses the authed account has bookmarked.

  Both paginate by the *interaction* id (likes.id / bookmarks.id) so
  Mastodon-style cursor pagination works even though the underlying status
  ordering is by snowflake.
  """

  use AnglerWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Angler.Pagination.MastodonCursor
  alias Angler.Repo
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.Plugs.BearerAuth

  def favourites(conn, params) do
    do_list(conn, params, Angler.Likes.Like)
  end

  def bookmarks(conn, params) do
    do_list(conn, params, Angler.Bookmarks.Bookmark)
  end

  defp do_list(conn, params, schema) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    cursor = MastodonCursor.parse(params, 20, 40)

    base = from r in schema, where: r.profile_id == ^profile.id

    rows =
      base
      |> MastodonCursor.apply(cursor, :id)
      |> Repo.all()
      |> MastodonCursor.finalize_order(cursor, :id)

    statuses =
      case rows do
        [] ->
          []

        rows ->
          status_ids = Enum.map(rows, & &1.status_id)

          Repo.all(
            from s in Angler.Statuses.Status,
              where: s.id in ^status_ids and is_nil(s.deleted_at),
              preload: [
                :profile,
                mentions: :profile,
                status_hashtags: :hashtag,
                media_attachments: []
              ]
          )
          |> sort_to_match(status_ids)
      end

    conn =
      case MastodonCursor.link_header(rows, current_url_without_cursor(conn), :id) do
        nil -> conn
        v -> put_resp_header(conn, "link", v)
      end

    json(conn, StatusJSON.render_many(statuses, profile.id))
  end

  defp sort_to_match(statuses, status_ids) do
    by_id = Map.new(statuses, fn s -> {s.id, s} end)
    Enum.flat_map(status_ids, fn id -> if s = Map.get(by_id, id), do: [s], else: [] end)
  end

  defp current_url_without_cursor(conn) do
    qs =
      conn.query_params
      |> Map.drop(["max_id", "min_id", "since_id"])
      |> Plug.Conn.Query.encode()

    base = current_url(conn) |> URI.parse() |> Map.put(:query, nil) |> URI.to_string()
    if qs == "", do: base, else: base <> "?" <> qs
  end
end
