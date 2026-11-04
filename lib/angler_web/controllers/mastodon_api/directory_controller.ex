defmodule AnglerWeb.MastodonAPI.DirectoryController do
  @moduledoc """
  Anonymous landing-page endpoints used by the unauthenticated splash UI.

    * GET /api/v1.1/landing/v1/directory — public profile directory listing.
    * GET /api/v1.1/landing/v1/explore   — recent public photo posts grid.

  Both gated by their own config flags so operators can hide them:

      config :angler, :landing_directory_enabled, true
      config :angler, :landing_explore_enabled, true
  """

  use AnglerWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses.Status
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON

  def index(conn, params) do
    if directory_enabled?() do
      do_index(conn, params)
    else
      not_found(conn)
    end
  end

  defp do_index(conn, params) do
    limit = parse_limit(params["limit"], 20)

    profiles =
      Repo.all(
        from p in Profile,
          where:
            is_nil(p.domain) and is_nil(p.status) and
              p.is_private == false and p.discoverable == true,
          order_by: [desc: p.updated_at],
          limit: ^limit
      )

    json(conn, Enum.map(profiles, &render_profile/1))
  end

  defp render_profile(p) do
    %{
      "id" => Integer.to_string(p.id),
      "username" => p.username,
      "display_name" => p.name || "",
      "avatar" => p.avatar_path || "",
      "header" => p.header_path || "",
      "url" => Profiles.url(p),
      "followers_count" => p.followers_count,
      "statuses_count" => p.statuses_count,
      "last_status_at" =>
        case p.last_status_at do
          %DateTime{} = dt -> DateTime.to_iso8601(dt)
          _ -> nil
        end
    }
  end

  # `limit` param clamped to 1..40; `default` when absent or not an integer.
  defp parse_limit(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n |> max(1) |> min(40)
      _ -> default
    end
  end

  defp parse_limit(_, default), do: default

  ## GET /landing/v1/explore — recent public photo/video posts grid.

  def explore(conn, params) do
    if explore_enabled?() do
      limit = parse_limit(params["limit"], 24)

      statuses =
        Repo.all(
          from s in Status,
            where:
              s.visibility == :public and is_nil(s.deleted_at) and
                s.is_nsfw == false and
                s.type in ["photo", "photo:album", "video", "video:album"],
            order_by: [desc: s.id],
            limit: ^limit
        )
        |> Repo.preload([
          :profile,
          mentions: :profile,
          status_hashtags: :hashtag,
          media_attachments: []
        ])

      json(conn, StatusJSON.render_many(statuses, nil))
    else
      not_found(conn)
    end
  end

  ## GET /directory/listing?sk=...
  ##
  ## Pixelfed federation directory submission endpoint. Only enabled when
  ## the operator has set `:pixelfed_directory_sk`; the caller must pass
  ## a matching `sk` to receive the instance metadata. Used by the central
  ## pixelfed.org directory crawler — local clients don't hit this.
  def listing(conn, params) do
    case Application.get_env(:angler, :pixelfed_directory_sk) do
      sk when is_binary(sk) and sk != "" ->
        case params["sk"] do
          nil ->
            not_found(conn)

          provided when is_binary(provided) ->
            if Plug.Crypto.secure_compare(provided, sk) do
              json(conn, build_listing(sk))
            else
              conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})
            end
        end

      _ ->
        not_found(conn)
    end
  end

  defp build_listing(sk) do
    cfg = Application.get_env(:angler, :pixelfed_directory, %{})

    base =
      cfg
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    endpoint_cfg = Application.get_env(:angler, AnglerWeb.Endpoint, [])
    url_cfg = endpoint_cfg[:url] || []
    host = url_cfg[:host] || "localhost"

    Map.merge(base, %{
      "_domain" => host,
      "_sk" => sk,
      "_ts" => DateTime.to_iso8601(DateTime.utc_now()),
      "version" => Application.spec(:angler, :vsn) |> to_string()
    })
  end

  ## Internals

  defp directory_enabled?,
    do: Application.get_env(:angler, :landing_directory_enabled, true) == true

  defp explore_enabled?,
    do: Application.get_env(:angler, :landing_explore_enabled, true) == true

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{"error" => "Not found"})
end
