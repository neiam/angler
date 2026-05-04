defmodule AnglerWeb.MastodonAPI.DirectoryController do
  @moduledoc """
  GET /api/v1.1/landing/v1/directory — public profile directory listing.

  Returns local profiles flagged `discoverable` and not suspended/locked.
  Anonymous endpoint; rate-limit at the reverse proxy if needed.
  """

  use AnglerWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo

  def index(conn, params) do
    limit =
      case params["limit"] do
        s when is_binary(s) ->
          case Integer.parse(s) do
            {n, ""} -> n |> max(1) |> min(40)
            _ -> 20
          end

        _ ->
          20
      end

    profiles =
      Repo.all(
        from p in Profile,
          where:
            is_nil(p.domain) and is_nil(p.status) and
              p.is_private == false and p.discoverable == true,
          order_by: [desc: p.updated_at],
          limit: ^limit
      )

    body =
      Enum.map(profiles, fn p ->
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
      end)

    json(conn, body)
  end
end
