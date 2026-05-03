defmodule AnglerWeb.MastodonAPI.SearchController do
  @moduledoc """
  GET /api/v2/search?q=&type=&limit=&account_id=&following=&resolve=

  Returns:

      { "accounts": [Account, ...],
        "statuses": [Status, ...],
        "hashtags": [Tag, ...] }

  When `type` is specified, only that bucket is populated. The rest are
  empty arrays so clients don't have to special-case.

  Status search currently looks at the viewer's own posts plus public/unlisted
  remote posts whose caption matches. There's no full-text index yet — this is
  an `ilike` over the prefix; good enough for the slice, replaceable with
  `pg_trgm` or external Tantivy/OpenSearch later.
  """

  use AnglerWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Angler.Hashtags.Hashtag
  alias Angler.Profiles
  alias Angler.Repo
  alias Angler.Statuses.Status
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.Plugs.BearerAuth

  @default_limit 20
  @max_limit 40

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
    Profiles.search(q, limit: limit) |> Enum.map(&Account.render/1)
  end

  defp search_hashtags(q, limit) do
    pattern = q |> String.trim_leading("#") |> String.downcase()
    pattern = pattern <> "%"

    Repo.all(
      from h in Hashtag,
        where: ilike(h.name, ^pattern),
        order_by: [desc: h.usage_count, asc: h.name],
        limit: ^limit
    )
    |> Enum.map(fn h ->
      %{
        "name" => h.name,
        "url" => AnglerWeb.Endpoint.url() <> "/tags/" <> h.name,
        "history" => []
      }
    end)
  end

  defp search_statuses(q, viewer_id, limit) do
    pattern = "%" <> q <> "%"

    base =
      from s in Status,
        where:
          is_nil(s.deleted_at) and
            ilike(s.caption, ^pattern) and
            (s.visibility in [:public, :unlisted] or s.profile_id == ^(viewer_id || -1)),
        order_by: [desc: s.id],
        limit: ^limit,
        preload: [:profile, mentions: :profile, status_hashtags: :hashtag, media_attachments: []]

    base
    |> Repo.all()
    |> StatusJSON.render_many(viewer_id)
  end

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n |> max(1) |> min(@max_limit)
      _ -> @default_limit
    end
  end

  defp parse_limit(_), do: @default_limit
end
