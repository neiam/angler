defmodule AnglerWeb.GroupsAPI.GroupsFeedController do
  @moduledoc """
  Group feed reads, plus a few small extras (notifications, profile
  feeds, topics). All endpoints respect `:groups_enabled`.
  """

  use AnglerWeb, :controller

  alias Angler.Groups
  alias Angler.Groups.Group
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.Plugs.BearerAuth

  ## GET /self/feed — aggregate of all groups the viewer is in.

  def self_feed(conn, _params) do
    if Groups.enabled?() do
      %{profile: profile} = BearerAuth.current_scope(conn)
      json(conn, StatusJSON.render_many(Groups.self_feed(profile), profile.id))
    else
      not_found(conn)
    end
  end

  ## GET /self/notifications — empty array; group notifications run
  ## through the existing notifications surface, no separate sink.

  def self_notifications(conn, _params),
    do: if(Groups.enabled?(), do: json(conn, []), else: not_found(conn))

  ## GET /:id/feed

  def group_feed(conn, %{"id" => id}) do
    with_group(conn, id, fn group ->
      viewer_id = viewer_id(conn)
      json(conn, StatusJSON.render_many(Groups.feed(group, viewer_id), viewer_id))
    end)
  end

  ## GET /:id/user/:pid/feed — viewer-scoped feed of one member's posts

  def group_profile_feed(conn, %{"id" => id, "pid" => pid}) do
    with_group(conn, id, fn group ->
      viewer_id = viewer_id(conn)

      case Integer.parse(to_string(pid)) do
        {profile_id, ""} ->
          all = Groups.feed(group, viewer_id, 60)
          filtered = Enum.filter(all, &(&1.profile_id == profile_id))
          json(conn, StatusJSON.render_many(filtered, viewer_id))

        _ ->
          not_found(conn)
      end
    end)
  end

  ## Topics — Pixelfed surfaces hashtag-style group topics. We don't
  ## carry a per-group topic table; mount empty arrays.

  def topics_list(conn, _params),
    do: if(Groups.enabled?(), do: json(conn, []), else: not_found(conn))

  def topic_tag(conn, _params),
    do: if(Groups.enabled?(), do: json(conn, []), else: not_found(conn))

  ## Internals

  defp with_group(conn, id, fun) do
    if Groups.enabled?() do
      case Groups.get(id) do
        nil -> not_found(conn)
        %Group{} = g -> fun.(g)
      end
    else
      not_found(conn)
    end
  end

  defp viewer_id(conn) do
    case BearerAuth.current_scope(conn) do
      %{profile: %{id: pid}} -> pid
      _ -> nil
    end
  end

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{"error" => "Not found"})
end
