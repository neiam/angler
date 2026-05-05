defmodule AnglerWeb.MastodonAPI.PlacesController do
  @moduledoc """
  GET /api/v1.1/places/posts/:id/:slug — public statuses geotagged to
  `(id, slug)`. Returns `{place, posts}` Pixelfed-shape envelope.
  """

  use AnglerWeb, :controller

  alias Angler.Places
  alias Angler.Places.Place
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.Plugs.BearerAuth

  ## GET /compose/search/location?q=...
  ##
  ## Used by the composer's place picker. Pixelfed bounds at 100 chars and
  ## requires `q`; we mirror that — short queries return up to 30 places,
  ## longer ones up to 60 (capped).
  def search_location(conn, params) do
    q = params["q"]

    cond do
      not is_binary(q) or String.trim(q) == "" ->
        conn |> put_status(:unprocessable_entity) |> json(%{"error" => "q is required"})

      String.length(q) > 100 ->
        conn |> put_status(:unprocessable_entity) |> json(%{"error" => "q is too long"})

      true ->
        limit = if String.length(q) > 5, do: 60, else: 30

        body =
          q
          |> Places.search(limit)
          |> Enum.map(fn %Place{} = p ->
            %{
              "id" => p.id,
              "name" => p.name,
              "slug" => p.slug,
              "country" => p.country,
              "lat" => p.lat,
              "long" => p.long
            }
          end)

        json(conn, body)
    end
  end

  def show(conn, %{"id" => id, "slug" => slug}) do
    viewer_id =
      case BearerAuth.current_scope(conn) do
        %{profile: %{id: pid}} -> pid
        _ -> nil
      end

    with {:ok, int_id} <- parse_id(id),
         %Place{} = place <- Places.get(int_id, slug) do
      statuses = Places.posts_at(place.id)

      json(conn, %{
        "place" => %{
          "id" => place.id,
          "name" => place.name,
          "slug" => place.slug,
          "country" => place.country,
          "lat" => place.lat,
          "long" => place.long
        },
        "posts" => StatusJSON.render_many(statuses, viewer_id)
      })
    else
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}
  defp parse_id(_), do: :error
end
