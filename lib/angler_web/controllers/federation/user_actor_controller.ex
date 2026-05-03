defmodule AnglerWeb.Federation.UserActorController do
  @moduledoc """
  GET /users/:username — the AP `Person` actor doc for a local profile.

  Federating peers fetch this to get our public key and inbox URL. We always
  return JSON regardless of `Accept` header for now (the HTML profile page is
  a separate route — out of scope for the federation slice).
  """

  use AnglerWeb, :controller

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
        |> send_resp(200, Jason.encode_to_iodata!(actor_json(profile)))
    end
  end

  defp actor_json(%Profile{} = p) do
    base = AnglerWeb.Endpoint.url()
    actor_url = base <> "/users/" <> p.username

    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1"
      ],
      "id" => actor_url,
      "type" => if(p.is_bot, do: "Service", else: "Person"),
      "preferredUsername" => p.username,
      "name" => p.name || p.username,
      "summary" => p.bio || "",
      "url" => base <> "/@" <> p.username,
      "inbox" => actor_url <> "/inbox",
      "outbox" => actor_url <> "/outbox",
      "followers" => actor_url <> "/followers",
      "following" => actor_url <> "/following",
      "manuallyApprovesFollowers" => p.is_private,
      "discoverable" => p.discoverable,
      "indexable" => p.indexable_search,
      "published" => p.inserted_at && DateTime.to_iso8601(p.inserted_at),
      "endpoints" => %{
        "sharedInbox" => base <> "/f/inbox"
      },
      "publicKey" => %{
        "id" => actor_url <> "#main-key",
        "owner" => actor_url,
        "publicKeyPem" => p.public_key_pem
      }
    }
  end
end
