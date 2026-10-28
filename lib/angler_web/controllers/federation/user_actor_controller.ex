defmodule AnglerWeb.Federation.UserActorController do
  @moduledoc """
  GET /users/:username — the AP `Person` actor doc for a local profile.

  GET /users/:username/{outbox,followers,following} — the collections the
  actor doc advertises. Like upstream, they carry only `totalItems`: peers
  get the counts, nobody gets the lists.

  GET /users/:username/followers_synchronization — FEP-8fcf: the profile's
  followers on the server that signed the request, so it can check its copy.

  GET /users/:username/quote_authorizations/:id — a FEP-044f stamp. Only
  ever issued for public and unlisted posts and holding nothing but ids, so
  it's public; 410 once revoked.

  GET /users/:username/stamps/:id — a FEP-7aa9 FeatureAuthorization stamp,
  likewise public and 410 once revoked.

  Federating peers fetch this to get our public key and inbox URL. We always
  return JSON regardless of `Accept` header for now (the HTML profile page is
  a separate route — out of scope for the federation slice).
  """

  use AnglerWeb, :controller

  alias Angler.FeaturedCollections
  alias Angler.Federation.{Actor, ActorBuilder, FollowersSync, HTTPSignature, HttpSignatureKey}
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Quotes
  alias Angler.Quotes.Authorization

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

  def followers_synchronization(conn, %{"username" => username}) do
    with %Profile{status: nil} = profile <- Profiles.get_local_by_username(username),
         {:ok, owner} <- signer(conn),
         auth when is_binary(auth) <- FollowersSync.authority(owner) do
      items = FollowersSync.partial_followers(profile, auth)

      body = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => ActorBuilder.actor_url(profile) <> "/followers_synchronization",
        "type" => "OrderedCollection",
        "totalItems" => length(items),
        "orderedItems" => items
      }

      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_content_type("application/activity+json")
      |> send_resp(200, Jason.encode_to_iodata!(body))
    else
      nil -> conn |> put_status(:not_found) |> json(%{"error" => "Not Found"})
      %Profile{} -> conn |> put_status(:not_found) |> json(%{"error" => "Not Found"})
      _ -> conn |> put_status(:unauthorized) |> json(%{"error" => "Unauthorized"})
    end
  end

  # Who signed this fetch: the owner of the verified key.
  defp signer(conn) do
    headers = [{"host", conn.host} | conn.req_headers]

    path =
      if conn.query_string == "",
        do: conn.request_path,
        else: conn.request_path <> "?" <> conn.query_string

    with {:ok, key_id} <- HTTPSignature.verify_fetch(path, headers, &Actor.public_key_for/1) do
      case Angler.Repo.get_by(HttpSignatureKey, key_id: key_id) do
        %HttpSignatureKey{owner_url: owner} -> {:ok, owner}
        nil -> {:ok, key_id |> URI.parse() |> Map.put(:fragment, nil) |> URI.to_string()}
      end
    end
  end

  def quote_authorization(conn, %{"username" => username, "id" => id}) do
    with %Profile{id: pid} <- Profiles.get_local_by_username(username),
         {id, ""} <- Integer.parse(id),
         %Authorization{} = auth <- Angler.Repo.get_by(Authorization, id: id, profile_id: pid),
         auth = Angler.Repo.preload(auth, :status),
         true <- Quotes.quotable?(auth.status) do
      if auth.state == "revoked" do
        conn |> put_status(:gone) |> json(%{"error" => "Gone"})
      else
        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(200, Jason.encode_to_iodata!(Quotes.stamp_object(auth)))
      end
    else
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Not Found"})
    end
  end

  def feature_authorization(conn, %{"username" => username, "id" => id}) do
    with %Profile{id: pid} <- Profiles.get_local_by_username(username),
         {id, ""} <- Integer.parse(id),
         %FeaturedCollections.Authorization{} = auth <-
           Angler.Repo.get_by(FeaturedCollections.Authorization, id: id, profile_id: pid) do
      if auth.state == "revoked" do
        conn |> put_status(:gone) |> json(%{"error" => "Gone"})
      else
        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(200, Jason.encode_to_iodata!(FeaturedCollections.stamp_object(auth)))
      end
    else
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Not Found"})
    end
  end
end
