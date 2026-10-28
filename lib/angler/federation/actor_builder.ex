defmodule Angler.Federation.ActorBuilder do
  @moduledoc """
  Builds the ActivityPub `Person` actor document for a local profile, and the
  `Update` activity that announces profile changes (avatar/header/name/bio) to
  remote followers.

  Shared by the actor endpoint (`AnglerWeb.Federation.UserActorController`) and
  the outbound update deliver (`Angler.Profiles.Workers.ActorUpdateDeliver`) so
  the fetched doc and the pushed update are identical — including `icon`/`image`,
  without which remote servers show no avatar at all — and the FEP-7aa9
  `interactionPolicy.canFeature` (`Angler.FeaturedCollections`).
  """

  alias Angler.FeaturedCollections
  alias Angler.Profiles.Profile
  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  @doc "The standalone `Person` (or `Service`) actor document."
  @spec person(Profile.t()) :: map()
  def person(%Profile{} = p) do
    actor_url = actor_url(p)

    %{
      "@context" => context(),
      "id" => actor_url,
      "type" => if(p.is_bot, do: "Service", else: "Person"),
      "preferredUsername" => p.username,
      "name" => p.name || p.username,
      "summary" => p.bio || "",
      "url" => base() <> "/@" <> p.username,
      "inbox" => actor_url <> "/inbox",
      "outbox" => actor_url <> "/outbox",
      "followers" => actor_url <> "/followers",
      "following" => actor_url <> "/following",
      "manuallyApprovesFollowers" => p.is_private,
      "discoverable" => p.discoverable,
      "indexable" => p.indexable_search,
      "published" => p.inserted_at && DateTime.to_iso8601(p.inserted_at),
      "endpoints" => %{"sharedInbox" => base() <> "/f/inbox"},
      "publicKey" => %{
        "id" => actor_url <> "#main-key",
        "owner" => actor_url,
        "publicKeyPem" => p.public_key_pem
      },
      "icon" => image_object(p.avatar_path),
      "image" => image_object(p.header_path),
      "interactionPolicy" => if(is_nil(p.status), do: FeaturedCollections.interaction_policy(p))
    }
    |> reject_nils()
  end

  @doc "An `Update` activity wrapping the actor, addressed to Public + followers."
  @spec update_activity(Profile.t()) :: map()
  def update_activity(%Profile{} = p) do
    actor_url = actor_url(p)
    object = person(p) |> Map.delete("@context")

    %{
      "@context" => context(),
      "id" => actor_url <> "#updates/" <> stamp(p),
      "type" => "Update",
      "actor" => actor_url,
      "to" => [@public_uri],
      "cc" => [actor_url <> "/followers"],
      "object" => object
    }
  end

  @doc """
  A `Delete` of the actor itself, for account deletion. The object is the
  bare `{id, type}` and it goes to followers, without Public, as upstream
  sends it (967ab88ec, cfc5c9387).
  """
  @spec delete_activity(Profile.t()) :: map()
  def delete_activity(%Profile{} = p) do
    actor_url = actor_url(p)

    %{
      "@context" => context(),
      "id" => actor_url <> "#delete",
      "type" => "Delete",
      "actor" => actor_url,
      "to" => [actor_url <> "/followers"],
      "object" => %{"id" => actor_url, "type" => "Person"}
    }
  end

  @doc "The canonical actor URL for a local profile."
  @spec actor_url(Profile.t()) :: String.t()
  def actor_url(%Profile{username: username}), do: base() <> "/users/" <> username

  ## Internals

  defp context do
    [
      "https://www.w3.org/ns/activitystreams",
      "https://w3id.org/security/v1",
      FeaturedCollections.actor_context_terms()
    ]
  end

  defp base, do: AnglerWeb.Endpoint.url()

  defp image_object(path) when is_binary(path) and path != "",
    do: %{"type" => "Image", "url" => absolute(path)}

  defp image_object(_), do: nil

  # avatar_path/header_path are usually absolute (Storage.url), but tolerate a
  # stored `/storage/...` path too — federation peers need an absolute URL.
  defp absolute("http" <> _ = url), do: url
  defp absolute(path), do: base() <> path

  defp stamp(%Profile{updated_at: %DateTime{} = at}),
    do: at |> DateTime.to_unix() |> Integer.to_string()

  defp stamp(_), do: "0"

  defp reject_nils(map), do: Map.reject(map, fn {_, v} -> is_nil(v) end)
end
