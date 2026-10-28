defmodule Angler.FeaturedCollections do
  @moduledoc """
  FEP-7aa9 featured collections, as upstream v0.15's FeaturedCollectionService.

  A remote account (Mastodon 4.5+) that wants to list a local profile in one
  of its `FeaturedCollection`s first sends a `FeatureRequest`. The profile's
  canFeature policy (`can_feature` account setting: `"everyone"`,
  `"followers"` or `"nobody"`, advertised as `interactionPolicy.canFeature`
  on the actor) decides, and an approval is a `FeatureAuthorization` stamp
  (`Angler.FeaturedCollections.Authorization`) the collection carries. Only
  automatic approval exists: anyone the policy doesn't approve is refused.

  Stamps are revoked (a `Delete` of the stamp goes to the collection owner)
  when the profile blocks the owner or their domain, or removes themselves
  on the settings page. A revoked stamp keeps repeat requests from that
  collection refused until the profile changes their policy.
  """

  import Ecto.Query, warn: false

  alias Angler.Accounts.{Settings, User}
  alias Angler.FeaturedCollections.Authorization
  alias Angler.Federation.{Actor, HTTP, InstanceActor}
  alias Angler.Follows
  alias Angler.Profiles
  alias Angler.Profiles.{BlocksMutes, DomainBlocks, Profile}
  alias Angler.Quotes.Workers.QuoteDeliver
  alias Angler.Repo

  @policies ~w(everyone followers nobody)
  @as_public "https://www.w3.org/ns/activitystreams#Public"
  @collection_type "FeaturedCollection"

  @stamp_context [
    "https://www.w3.org/ns/activitystreams",
    %{
      "gts" => "https://gotosocial.org/ns#",
      "FeatureAuthorization" => "https://w3id.org/fep/7aa9#FeatureAuthorization",
      "interactingObject" => %{"@id" => "gts:interactingObject", "@type" => "@id"},
      "interactionTarget" => %{"@id" => "gts:interactionTarget", "@type" => "@id"}
    }
  ]

  def policies, do: @policies

  @doc """
  JSON-LD terms for the actor's `interactionPolicy.canFeature`, merged into
  its @context so it compacts as on Mastodon.
  """
  def actor_context_terms do
    %{
      "gts" => "https://gotosocial.org/ns#",
      "interactionPolicy" => %{"@id" => "gts:interactionPolicy", "@type" => "@id"},
      "canFeature" => %{"@id" => "https://w3id.org/fep/7aa9#canFeature", "@type" => "@id"},
      "automaticApproval" => %{"@id" => "gts:automaticApproval", "@type" => "@id"},
      "manualApproval" => %{"@id" => "gts:manualApproval", "@type" => "@id"}
    }
  end

  ## Policy

  @doc "A local profile's canFeature policy; remote profiles are `\"nobody\"`."
  @spec policy(Profile.t()) :: String.t()
  def policy(%Profile{domain: nil, id: pid}) do
    with %User{id: uid} <- Repo.get_by(User, profile_id: pid),
         p when p in @policies <- Settings.account_settings(uid)["can_feature"] do
      p
    else
      _ -> "everyone"
    end
  end

  def policy(_), do: "nobody"

  @doc "A `can_feature` setting value, or nil if it isn't one."
  @spec policy_param(term()) :: String.t() | nil
  def policy_param(p) when p in @policies, do: p
  def policy_param(_), do: nil

  @doc """
  The actor's `interactionPolicy`. Nobody is expressed as the actor's own
  id, since an empty list is the same as a missing property in JSON-LD.
  """
  @spec interaction_policy(Profile.t()) :: map()
  def interaction_policy(%Profile{} = profile) do
    actor_url = Profiles.actor_url(profile)

    uri =
      case policy(profile) do
        "everyone" -> @as_public
        "followers" -> actor_url <> "/followers"
        _ -> actor_url
      end

    %{"canFeature" => %{"automaticApproval" => [uri]}}
  end

  @doc """
  May remote `actor` feature local `target`? Policy, blocks and domain
  blocks; a revoked stamp for the same collection is the caller's to check.
  """
  @spec can_feature?(Profile.t(), Profile.t()) :: boolean()
  def can_feature?(%Profile{} = target, %Profile{} = actor) do
    cond do
      not active_local?(target) -> false
      is_nil(actor.domain) or not is_nil(actor.status) -> false
      BlocksMutes.blocked?(target.id, actor.id) -> false
      DomainBlocks.blocked?(target.id, actor.domain) -> false
      true -> allowed_by_policy?(policy(target), target, actor)
    end
  end

  defp allowed_by_policy?("everyone", _, _), do: true

  defp allowed_by_policy?("followers", target, actor),
    do: match?(%{accepted_at: %DateTime{}}, Follows.get_follower(target.id, actor.id))

  defp allowed_by_policy?(_, _, _), do: false

  @doc "Local, not deleted or suspended."
  @spec active_local?(Profile.t()) :: boolean()
  def active_local?(%Profile{domain: nil, status: nil, is_suspended: false}), do: true
  def active_local?(_), do: false

  @doc """
  The profile changed who may feature them: earlier refusals no longer
  stand, so their deny-records go (upstream PrivacySettings).
  """
  @spec policy_changed(integer()) :: :ok
  def policy_changed(profile_id) do
    {_, _} =
      Repo.delete_all(
        from a in Authorization, where: a.profile_id == ^profile_id and a.state == "revoked"
      )

    :ok
  end

  ## The remote collection

  @doc """
  Fetch a remote `FeaturedCollection` and confirm it is the one at `url`
  and belongs to `owner`. Returns its id, name and summary, or nil.
  """
  @spec fetch_collection(String.t(), Profile.t()) ::
          %{id: String.t(), name: String.t() | nil, summary: String.t() | nil} | nil
  def fetch_collection(url, %Profile{remote_url: owner_url}) do
    instance = InstanceActor.ensure!()

    with {:ok, %{"id" => id} = doc} when is_binary(id) <-
           HTTP.fetch(url, signed_with: {instance.key_id, instance.private_key_pem}),
         true <- @collection_type in List.wrap(doc["type"]),
         true <- Actor.same_actor?(id, url),
         true <- Actor.same_actor?(ref(doc["attributedTo"]), owner_url) do
      %{id: id, name: clean_text(doc["name"], 200), summary: clean_text(doc["summary"], 500)}
    else
      _ -> nil
    end
  end

  defp ref([first | _]), do: ref(first)
  defp ref(%{"id" => id}), do: ref(id)
  defp ref(id) when is_binary(id), do: id
  defp ref(_), do: nil

  defp clean_text(value, max) when is_binary(value) do
    case value |> String.replace(~r/<[^>]*>/, "") |> String.trim() do
      "" -> nil
      text -> String.slice(text, 0, max)
    end
  end

  defp clean_text(_, _), do: nil

  ## Stamps

  @spec find(integer(), String.t()) :: Authorization.t() | nil
  def find(profile_id, collection_url),
    do: Repo.get_by(Authorization, profile_id: profile_id, collection_url: collection_url)

  @doc "Issue (or reuse, refreshing its name) the stamp for a collection."
  @spec authorize(Profile.t(), Profile.t(), String.t(), String.t() | nil, String.t() | nil) ::
          Authorization.t()
  def authorize(%Profile{} = target, %Profile{} = actor, collection_url, request_url, name) do
    %Authorization{
      id: Angler.Snowflake.next(),
      profile_id: target.id,
      actor_id: actor.id,
      collection_url: collection_url,
      collection_name: name,
      request_url: request_url
    }
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:profile_id, :collection_url])

    auth = find(target.id, collection_url)

    if name && auth.collection_name != name,
      do: auth |> Ecto.Changeset.change(collection_name: name) |> Repo.update!(),
      else: auth
  end

  @doc "A profile's approved stamps, newest first, for the settings page."
  @spec list_approved(integer(), pos_integer()) :: [Authorization.t()]
  def list_approved(profile_id, limit \\ 50) do
    Repo.all(
      from a in Authorization,
        where: a.profile_id == ^profile_id and a.state == "approved",
        order_by: [desc: a.id],
        limit: ^limit,
        preload: [:actor]
    )
  end

  @doc """
  Withdraw consent: the row stays, revoked (the stamp URL then serves 410
  and a repeat request is refused), and the collection owner gets a `Delete`.
  """
  @spec revoke(Authorization.t()) :: :ok
  def revoke(%Authorization{state: "revoked"}), do: :ok

  def revoke(%Authorization{} = auth) do
    auth = Repo.preload(auth, [:profile, :actor])
    activity = delete_activity(auth)

    auth
    |> Ecto.Changeset.change(state: "revoked", revoked_at: DateTime.utc_now())
    |> Repo.update!()

    {:ok, _} = QuoteDeliver.enqueue(auth.profile_id, auth.actor_id, activity)
    :ok
  end

  @doc "Revoke one of `profile_id`'s stamps by id. `:not_found` if it isn't theirs."
  @spec revoke(integer(), integer()) :: :ok | :not_found
  def revoke(profile_id, id) do
    case Repo.get_by(Authorization, id: id, profile_id: profile_id) do
      nil -> :not_found
      auth -> revoke(auth)
    end
  end

  @doc "Revoke every stamp `profile_id` gave `actor_id` (they blocked them)."
  @spec revoke_for_actor(integer(), integer()) :: :ok
  def revoke_for_actor(profile_id, actor_id) do
    from(a in Authorization,
      where: a.profile_id == ^profile_id and a.actor_id == ^actor_id and a.state == "approved"
    )
    |> Repo.all()
    |> Enum.each(&revoke/1)
  end

  @doc "Revoke every stamp `profile_id` gave anyone on `domain`."
  @spec revoke_for_domain(integer(), String.t()) :: :ok
  def revoke_for_domain(profile_id, domain) do
    domain = String.downcase(domain)

    from(a in Authorization,
      join: p in Profile,
      on: p.id == a.actor_id,
      where: a.profile_id == ^profile_id and a.state == "approved" and p.domain == ^domain
    )
    |> Repo.all()
    |> Enum.each(&revoke/1)
  end

  @doc "A remote account is gone: so are the stamps it held."
  @spec actor_deleted(integer()) :: :ok
  def actor_deleted(actor_id) do
    {_, _} = Repo.delete_all(from a in Authorization, where: a.actor_id == ^actor_id)
    :ok
  end

  ## Activities

  @spec stamp_url(Authorization.t()) :: String.t()
  def stamp_url(%Authorization{} = auth) do
    auth = Repo.preload(auth, :profile)
    Profiles.actor_url(auth.profile) <> "/stamps/" <> Integer.to_string(auth.id)
  end

  @doc "The stamp object, served at its URL and embedded in the revoking Delete."
  @spec stamp_object(Authorization.t()) :: map()
  def stamp_object(%Authorization{} = auth) do
    auth = Repo.preload(auth, :profile)

    %{
      "@context" => @stamp_context,
      "id" => stamp_url(auth),
      "type" => "FeatureAuthorization",
      "interactingObject" => auth.collection_url,
      "interactionTarget" => Profiles.actor_url(auth.profile)
    }
  end

  @doc "Accept of a FeatureRequest: `object` is the request id, `result` the stamp."
  @spec accept_activity(Authorization.t(), Profile.t(), String.t()) :: map()
  def accept_activity(%Authorization{} = auth, %Profile{} = requester, request_url) do
    auth = Repo.preload(auth, :profile)
    target_url = Profiles.actor_url(auth.profile)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => target_url <> "#accepts/features/" <> Integer.to_string(auth.id),
      "type" => "Accept",
      "actor" => target_url,
      "to" => Profiles.actor_url(requester),
      "object" => request_url,
      "result" => stamp_url(auth)
    }
  end

  @spec reject_activity(Profile.t(), Profile.t(), String.t()) :: map()
  def reject_activity(%Profile{} = target, %Profile{} = requester, request_url) do
    target_url = Profiles.actor_url(target)

    digest =
      :crypto.hash(:sha256, request_url) |> Base.encode16(case: :lower) |> binary_part(0, 16)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => target_url <> "#rejects/features/" <> digest,
      "type" => "Reject",
      "actor" => target_url,
      "to" => Profiles.actor_url(requester),
      "object" => request_url
    }
  end

  defp delete_activity(%Authorization{} = auth) do
    {context, object} = auth |> stamp_object() |> Map.pop("@context")

    %{
      "@context" => context,
      "id" => object["id"] <> "#delete",
      "type" => "Delete",
      "actor" => Profiles.actor_url(auth.profile),
      "to" => Profiles.actor_url(auth.actor),
      "object" => object
    }
  end
end
