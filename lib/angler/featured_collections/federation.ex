defmodule Angler.FeaturedCollections.Federation do
  @moduledoc """
  Inbound FEP-7aa9 `FeatureRequest`: a remote actor asks to list a local
  profile in one of its `FeaturedCollection`s (upstream HandlesFeatureRequests).

  The request, its collection (`instrument`) and its sender must all be on
  one host, and the collection is fetched to check it really is a
  FeaturedCollection owned by the sender. Requests that don't name a real
  remote sender and an active local profile are dropped unanswered;
  otherwise the answer is an `Accept` carrying the stamp or a `Reject`.
  """

  require Logger

  alias Angler.FeaturedCollections
  alias Angler.FeaturedCollections.Authorization
  alias Angler.Federation.Actor
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Quotes.Workers.QuoteDeliver

  @doc """
  `actor_url` is the signature-verified sender. A FeatureRequest often has
  no `actor`; when it does, it must be the sender.
  """
  @spec handle_feature_request(map(), String.t()) :: :ok
  def handle_feature_request(%{"id" => request_url} = activity, actor_url)
      when is_binary(request_url) and byte_size(request_url) <= 500 do
    with true <- claimed_actor_ok?(activity["actor"], actor_url),
         true <- Actor.same_host?(request_url, actor_url),
         collection_url when is_binary(collection_url) <- instrument_url(activity, actor_url),
         %Profile{} = target <- target(activity),
         {:ok, %Profile{domain: d} = actor} when is_binary(d) <- Actor.resolve(actor_url) do
      answer(target, actor, collection_url, request_url)
    else
      _ -> :ok
    end
  end

  def handle_feature_request(_, _), do: :ok

  defp answer(target, actor, collection_url, request_url) do
    case FeaturedCollections.find(target.id, collection_url) do
      %Authorization{state: "revoked"} ->
        reject(target, actor, request_url)

      %Authorization{} = auth ->
        accept(auth, actor, request_url)

      nil ->
        with true <- FeaturedCollections.can_feature?(target, actor),
             %{id: id, name: name} <- FeaturedCollections.fetch_collection(collection_url, actor) do
          target
          |> FeaturedCollections.authorize(actor, id, request_url, name)
          |> accept(actor, request_url)
        else
          _ ->
            Logger.info("FeatureRequest rejected: actor=#{actor.id} profile=#{target.id}")
            reject(target, actor, request_url)
        end
    end
  end

  defp accept(auth, actor, request_url) do
    activity = FeaturedCollections.accept_activity(auth, actor, request_url)
    {:ok, _} = QuoteDeliver.enqueue(auth.profile_id, actor.id, activity)
    :ok
  end

  defp reject(target, actor, request_url) do
    activity = FeaturedCollections.reject_activity(target, actor, request_url)
    {:ok, _} = QuoteDeliver.enqueue(target.id, actor.id, activity)
    :ok
  end

  defp claimed_actor_ok?(nil, _), do: true
  defp claimed_actor_ok?(claimed, actor_url), do: Actor.same_actor?(url_field(claimed), actor_url)

  defp instrument_url(activity, actor_url) do
    case url_field(activity["instrument"]) do
      url when is_binary(url) and byte_size(url) <= 500 ->
        if Actor.same_host?(url, actor_url), do: url

      _ ->
        nil
    end
  end

  # The local profile being featured: our actor URL for an active account.
  defp target(activity) do
    base = AnglerWeb.Endpoint.url() <> "/users/"

    with url when is_binary(url) <- url_field(activity["object"]),
         true <- String.starts_with?(url, base),
         username = url |> String.replace_prefix(base, "") |> String.trim_trailing("/"),
         true <- username =~ ~r/\A[^\/?#]+\z/,
         %Profile{} = profile <- Profiles.get_local_by_username(username),
         true <- FeaturedCollections.active_local?(profile) do
      profile
    else
      _ -> nil
    end
  end

  defp url_field([first | _]), do: url_field(first)
  defp url_field(%{"id" => id}), do: url_field(id)

  defp url_field(id) when is_binary(id) do
    id = String.trim(id)

    case URI.parse(id) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> id
      _ -> nil
    end
  end

  defp url_field(_), do: nil
end
