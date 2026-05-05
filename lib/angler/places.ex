defmodule Angler.Places do
  @moduledoc """
  Place lookup + post listing for the Pixelfed `places/posts/:id/:slug`
  endpoint. We expose creation through `ensure!/1` so future status-create
  flows can attach a place by name; geocoding (lat/long lookup) is left
  to whatever pipeline the operator wires up.
  """

  import Ecto.Query, warn: false

  alias Angler.Places.Place
  alias Angler.Repo
  alias Angler.Statuses.Status

  @spec get(integer(), String.t()) :: Place.t() | nil
  def get(id, slug) when is_integer(id) and is_binary(slug) do
    Repo.get_by(Place, id: id, slug: String.downcase(slug))
  end

  @spec ensure!(map()) :: Place.t()
  def ensure!(%{name: name} = attrs) when is_binary(name) do
    slug = attrs[:slug] || slugify(name)

    case Repo.get_by(Place, slug: slug) do
      %Place{} = p ->
        p

      nil ->
        attrs = Map.put(attrs, :slug, slug)
        {:ok, p} = %Place{} |> Place.changeset(attrs) |> Repo.insert()
        p
    end
  end

  @doc """
  Case-insensitive name search for the `compose/search/location` endpoint.
  Limit is bounded so a runaway query can't drag the request thread down.
  """
  @spec search(String.t(), pos_integer()) :: [Place.t()]
  def search(q, limit \\ 30) when is_binary(q) do
    cond do
      String.trim(q) == "" ->
        []

      true ->
        bounded = limit |> max(1) |> min(60)
        pattern = "%" <> escape_like(q) <> "%"

        Repo.all(
          from p in Place,
            where: ilike(p.name, ^pattern),
            order_by: [asc: p.name],
            limit: ^bounded
        )
    end
  end

  defp escape_like(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @spec posts_at(integer(), pos_integer()) :: [Status.t()]
  def posts_at(place_id, limit \\ 60) do
    Repo.all(
      from s in Status,
        where:
          s.place_id == ^place_id and is_nil(s.deleted_at) and
            s.visibility == :public,
        order_by: [desc: s.id],
        limit: ^limit
    )
    |> Repo.preload([
      :profile,
      mentions: :profile,
      status_hashtags: :hashtag,
      media_attachments: []
    ])
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
