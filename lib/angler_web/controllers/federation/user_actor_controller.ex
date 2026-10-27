defmodule AnglerWeb.Federation.UserActorController do
  @moduledoc """
  GET /users/:username — the AP `Person` actor doc for a local profile.

  GET /users/:username/{outbox,followers,following} — the collections the
  actor doc advertises. Like upstream, they carry only `totalItems`: peers
  get the counts, nobody gets the lists.

  Federating peers fetch this to get our public key and inbox URL. We always
  return JSON regardless of `Accept` header for now (the HTML profile page is
  a separate route — out of scope for the federation slice).
  """

  use AnglerWeb, :controller

  alias Angler.Federation.ActorBuilder
  alias Angler.Profiles
  alias Angler.Profiles.Profile

  def show(conn, %{"username" => username}) do
    case Profiles.get_local_by_username(username) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "Not Found"})

      %Profile{} = profile ->
        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(200, Jason.encode_to_iodata!(ActorBuilder.person(profile)))
    end
  end

  def outbox(conn, params), do: collection(conn, params, "outbox", & &1.statuses_count)
  def followers(conn, params), do: collection(conn, params, "followers", & &1.followers_count)
  def following(conn, params), do: collection(conn, params, "following", & &1.following_count)

  defp collection(conn, %{"username" => username}, name, count) do
    case Profiles.get_local_by_username(username) do
      nil ->
        conn |> put_status(:not_found) |> json(%{"error" => "Not Found"})

      %Profile{} = profile ->
        body = %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => ActorBuilder.actor_url(profile) <> "/" <> name,
          "type" => "OrderedCollection",
          "totalItems" => count.(profile) || 0
        }

        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(200, Jason.encode_to_iodata!(body))
    end
  end
end
