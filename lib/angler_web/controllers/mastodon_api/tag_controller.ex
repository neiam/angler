defmodule AnglerWeb.MastodonAPI.TagController do
  @moduledoc """
    * GET   /api/v1/tags/:id          — show (with `following` flag)
    * POST  /api/v1/tags/:id/follow   — follow
    * POST  /api/v1/tags/:id/unfollow — unfollow
    * GET   /api/v1/followed_tags     — list
  """

  use AnglerWeb, :controller

  alias Angler.Hashtags
  alias Angler.Hashtags.Following, as: HashtagFollows
  alias AnglerWeb.Plugs.BearerAuth

  def show(conn, %{"id" => name}) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    name = canon(name)

    case Hashtags.get_by_name(name) do
      nil -> not_found(conn)
      tag -> json(conn, render_tag(tag, HashtagFollows.following?(profile.id, tag.id)))
    end
  end

  def follow(conn, %{"id" => name}) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    {:ok, tag} = HashtagFollows.follow(profile, canon(name))
    json(conn, render_tag(tag, true))
  end

  def unfollow(conn, %{"id" => name}) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    name = canon(name)
    :ok = HashtagFollows.unfollow(profile, name)

    case Hashtags.get_by_name(name) do
      nil -> json(conn, render_tag(%{name: name, id: nil}, false))
      tag -> json(conn, render_tag(tag, false))
    end
  end

  def followed(conn, _params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    json(conn, Enum.map(HashtagFollows.list(profile.id), &render_tag(&1, true)))
  end

  ## Internals

  defp render_tag(%{name: name} = tag, following?) do
    %{
      "name" => name,
      "url" => AnglerWeb.Endpoint.url() <> "/tags/" <> name,
      "history" => [],
      "following" => following?,
      "id" => Map.get(tag, :id) && Integer.to_string(tag.id)
    }
  end

  defp canon(name), do: name |> String.trim_leading("#") |> String.downcase()

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
end
