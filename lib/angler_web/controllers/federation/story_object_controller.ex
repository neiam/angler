defmodule AnglerWeb.Federation.StoryObjectController do
  @moduledoc """
  GET /stories/:username/:id — ActivityPub object representation of a
  published story. Authorized by a `bearcap_token` (capabilities-based,
  not OAuth) presented as `Authorization: Bearer <token>`.

  Mirrors Pixelfed's `StoryController@getActivityObject`. Constraints:

    * Stories must be enabled (`:stories_enabled`); else 404.
    * The bearer must match the story's `bearcap_token` (constant-time).
    * The story must still be inside its publish window (we treat 20
      minutes as the freshness gate, matching upstream).
    * The story must be active and not expired.

  Browser GETs (`Accept: text/html`) get redirected to the user's
  profile, since this URL is meant for AP fetchers, not humans.
  """

  use AnglerWeb, :controller

  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Stories
  alias Angler.Stories.Story

  @freshness_seconds 20 * 60

  def show(conn, %{"username" => username, "id" => id}) do
    cond do
      not Stories.enabled?() ->
        not_found(conn)

      not wants_json?(conn) ->
        Phoenix.Controller.redirect(conn, to: "/users/" <> username)

      true ->
        with %Profile{} = author <- Profiles.get_local_by_username(username),
             {:ok, sid} <- parse_id(id),
             %Story{} = story <- Repo.get_by(Story, id: sid, profile_id: author.id),
             :ok <- validate(story, conn) do
          json(conn, render_ap(story, author))
        else
          _ -> not_found(conn)
        end
    end
  end

  defp validate(%Story{active: false}, _), do: :error

  defp validate(%Story{bearcap_token: nil}, _), do: :error

  defp validate(%Story{} = s, conn) do
    cond do
      DateTime.compare(s.expires_at, DateTime.utc_now()) == :lt ->
        :error

      DateTime.diff(DateTime.utc_now(), s.inserted_at, :second) > @freshness_seconds ->
        :error

      not bearer_matches?(conn, s.bearcap_token) ->
        :error

      true ->
        :ok
    end
  end

  defp bearer_matches?(conn, token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> presented] -> Plug.Crypto.secure_compare(presented, token)
      ["bearer " <> presented] -> Plug.Crypto.secure_compare(presented, token)
      _ -> false
    end
  end

  defp render_ap(%Story{} = s, %Profile{} = author) do
    actor_url = AnglerWeb.Endpoint.url() <> "/users/" <> author.username

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "type" => "Story",
      "id" =>
        AnglerWeb.Endpoint.url() <>
          "/stories/" <> author.username <> "/" <> Integer.to_string(s.id),
      "actor" => actor_url,
      "to" => [actor_url <> "/followers"],
      "published" => DateTime.to_iso8601(s.inserted_at),
      "expires" => DateTime.to_iso8601(s.expires_at),
      "duration" => "PT#{div(s.duration_ms, 1000)}S",
      "attachment" => [
        %{
          "type" => media_ap_type(s.type),
          "mediaType" => s.mime,
          "url" =>
            Angler.Media.Storage.backend().url(
              %Angler.Media.Asset{path_original: s.path},
              :original
            ) || s.path
        }
      ]
    }
  end

  defp media_ap_type("photo"), do: "Image"
  defp media_ap_type("video"), do: "Video"
  defp media_ap_type(_), do: "Document"

  defp wants_json?(conn) do
    case get_req_header(conn, "accept") do
      [] ->
        true

      [accept | _] ->
        String.contains?(accept, "json") or String.contains?(accept, "activity")
    end
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{"error" => "Not found"})
end
