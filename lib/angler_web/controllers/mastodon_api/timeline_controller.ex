defmodule AnglerWeb.MastodonAPI.TimelineController do
  @moduledoc """
  GET /api/v1/timelines/{home,public,tag/:hashtag}.

  Cursor pagination + Link header per `plans/_types/link_header.md`.
  """

  use AnglerWeb, :controller

  alias Angler.Pagination.MastodonCursor
  alias Angler.Timelines
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.Plugs.BearerAuth

  @default_limit 20
  @max_limit 40

  ## GET /timelines/home

  # Boosts: `include_reblogs` / `photos_reblogs_only` when sent, else the
  # user's timeline settings (`/api/v2.1/account/timeline/settings`). The
  # Pixelfed app follows the reblogs setting, off by default as upstream;
  # Mastodon clients expect boosts, so for them it defaults on.
  def home(conn, params) do
    %{profile: profile, user: user} = BearerAuth.current_scope(conn)
    cursor = MastodonCursor.parse(params, @default_limit, @max_limit)
    pe? = pe?(params)
    web = Angler.Accounts.Settings.get(user.id).web || %{}

    opts = [
      include_reblogs:
        bool_param(
          params["include_reblogs"],
          if(pe?, do: web["enable_reblogs"] == true, else: true)
        ),
      photos_reblogs_only:
        bool_param(params["photos_reblogs_only"], web["photo_reblogs_only"] == true)
    ]

    {statuses, cursor_rows} = Timelines.home(profile.id, cursor, opts)
    respond(conn, statuses, cursor_rows, profile.id, "home", pe: pe?)
  end

  defp pe?(params), do: Map.has_key?(params, "_pe")

  defp bool_param(nil, default), do: default
  defp bool_param(v, _default), do: v in [true, "true", "1", 1]

  ## GET /timelines/public

  def public(conn, params) do
    cursor = MastodonCursor.parse(params, @default_limit, @max_limit)

    opts = [
      local_only: truthy?(params["local"]),
      remote_only: truthy?(params["remote"]),
      only_media: truthy?(params["only_media"]),
      viewer_id: viewer_id(conn)
    ]

    {statuses, cursor_rows} = Timelines.public(cursor, opts)
    respond(conn, statuses, cursor_rows, viewer_id(conn), "public")
  end

  ## GET /timelines/tag/:hashtag

  def hashtag(conn, %{"hashtag" => name} = params) do
    cursor = MastodonCursor.parse(params, @default_limit, @max_limit)

    opts = [
      local_only: truthy?(params["local"]),
      remote_only: truthy?(params["remote"]),
      only_media: truthy?(params["only_media"]),
      viewer_id: viewer_id(conn)
    ]

    {statuses, cursor_rows} = Timelines.hashtag(name, cursor, opts)
    respond(conn, statuses, cursor_rows, viewer_id(conn), "public")
  end

  ## Internals

  defp respond(conn, statuses, cursor_rows, viewer_id, context, opts \\ []) do
    rendered = StatusJSON.render_many(statuses, viewer_id, [context: context] ++ opts)

    conn =
      case MastodonCursor.link_header(cursor_rows, current_url_without_cursor(conn), :id) do
        nil -> conn
        v -> put_resp_header(conn, "link", v)
      end

    json(conn, rendered)
  end

  defp viewer_id(conn) do
    case BearerAuth.current_scope(conn) do
      nil -> nil
      %{profile: %{id: id}} -> id
    end
  end

  defp current_url_without_cursor(conn) do
    # Build a clean base URL stripped of cursor params; MastodonCursor injects
    # the right ones for next/prev.
    qs =
      conn.query_params
      |> Map.drop(["max_id", "min_id", "since_id"])
      |> URI.encode_query()

    base = current_url(conn) |> URI.parse() |> Map.put(:query, nil) |> URI.to_string()
    if qs == "", do: base, else: base <> "?" <> qs
  end

  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(true), do: true
  defp truthy?(_), do: false
end
