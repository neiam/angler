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

  # Pixelfed caps a user at 25 followed hashtags (HashtagFollow::MAX_LIMIT).
  @max_follows 25

  def show(conn, %{"id" => name}) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    name = canon(name)

    case Hashtags.get_by_name(name) do
      # Pixelfed returns 200 with `following: false` for a tag that has no row
      # yet (not 404), so the app can render the follow button on a
      # never-before-seen hashtag. Mirror that.
      nil -> json(conn, render_tag(%{name: name, id: nil}, false))
      tag -> json(conn, render_tag(tag, HashtagFollows.following?(profile.id, tag.id)))
    end
  end

  def follow(conn, %{"id" => name}) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    name = canon(name)
    existing = Hashtags.get_by_name(name)
    already? = existing != nil and HashtagFollows.following?(profile.id, existing.id)

    if not already? and HashtagFollows.count(profile.id) >= @max_follows do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{"error" => "You can only follow #{@max_follows} hashtags."})
    else
      {:ok, tag} = HashtagFollows.follow(profile, name)
      json(conn, render_tag(tag, true))
    end
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

  ## GET /tags/:id/related — co-occurring hashtags
  ##
  ## Pixelfed has a HashtagRelatedService that mines tag co-occurrence
  ## from posts. We don't run that pipeline yet; mirror the empty-list
  ## response so clients that ask don't see a 404.
  def related(conn, _params), do: json(conn, [])

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
end
