defmodule Angler.Federation.Relays do
  @moduledoc """
  ActivityPub relay subscriptions.

  A relay lets the instance subscribe to a shared firehose of public posts.
  Following the LitePub/Pleroma model (e.g. `https://relay.toot.io/actor`), we
  `Follow` the relay's **actor** directly — signed by the instance actor —
  after discovering its inbox from the actor document. The relay replies
  `Accept` and then forwards `Announce` (or `Create`) activities to our
  instance-actor inbox. `Undo Follow` unsubscribes.

  Following a relay is purely a server-level action — no user is involved.
  Inbound relayed `Announce`s are ingested as ordinary public remote statuses
  (see `Angler.Statuses.Federation.ingest_announced/1`), gated on
  `relay_actor?/1` so we never ingest an arbitrary stranger's `Announce`
  target.
  """

  import Ecto.Query, warn: false

  alias Angler.Federation.HTTP
  alias Angler.Federation.InstanceActor
  alias Angler.Federation.Relay
  alias Angler.Federation.Workers.RelayDeliver
  alias Angler.Repo

  @spec list() :: [Relay.t()]
  def list, do: Repo.all(from r in Relay, order_by: [asc: r.id])

  @spec get(integer()) :: Relay.t() | nil
  def get(id), do: Repo.get(Relay, id)

  @spec get_by_actor_url(String.t()) :: Relay.t() | nil
  def get_by_actor_url(actor_url) when is_binary(actor_url),
    do: Repo.get_by(Relay, actor_url: actor_url)

  @doc """
  Subscribe to a relay by its **actor URL** (e.g. `https://relay.toot.io/actor`):
  fetch the actor to discover its inbox, create a `:pending` row, and send the
  `Follow`. Fails if the actor is already registered or unreachable.
  """
  @spec subscribe(String.t()) :: {:ok, Relay.t()} | {:error, term()}
  def subscribe(actor_url) when is_binary(actor_url) do
    with {:ok, inbox_url} <- discover_inbox(actor_url),
         attrs = %{
           actor_url: actor_url,
           inbox_url: inbox_url,
           follow_activity_id: mint_follow_id(),
           state: :pending
         },
         {:ok, relay} <- %Relay{} |> Relay.changeset(attrs) |> Repo.insert() do
      enqueue(:follow, relay)
      {:ok, relay}
    end
  end

  @doc "Re-send the `Follow` for an idle relay (mints a fresh Follow id)."
  @spec enable(Relay.t()) :: {:ok, Relay.t()}
  def enable(%Relay{} = relay) do
    {:ok, relay} =
      relay
      |> Relay.changeset(%{follow_activity_id: mint_follow_id(), state: :pending})
      |> Repo.update()

    enqueue(:follow, relay)
    {:ok, relay}
  end

  @doc "Send an `Undo Follow` and mark the relay idle (kept for re-enable)."
  @spec disable(Relay.t()) :: {:ok, Relay.t()}
  def disable(%Relay{} = relay) do
    enqueue(:undo, relay)
    relay |> Relay.changeset(%{state: :idle}) |> Repo.update()
  end

  @doc "Send an `Undo Follow` (if active) and delete the subscription."
  @spec unsubscribe(Relay.t()) :: :ok
  def unsubscribe(%Relay{} = relay) do
    if relay.state == :accepted, do: enqueue(:undo, relay)
    Repo.delete(relay)
    :ok
  end

  @doc """
  Mark a relay accepted from an inbound `Accept`, confirming the relay's actor
  URL from the Accept's signer (authoritative for later `Announce` matching).
  Returns `:not_found` if `follow_activity_id` matches no relay (so the caller
  can fall through to user-follow Accept handling).
  """
  @spec accept(String.t(), String.t() | nil) :: :ok | :not_found
  def accept(follow_activity_id, actor_url) when is_binary(follow_activity_id) do
    case Repo.get_by(Relay, follow_activity_id: follow_activity_id) do
      nil ->
        :not_found

      %Relay{} = relay ->
        # The Accept's signer is what `Announce`s will be signed by; trust it
        # over the subscribed URL if they differ.
        changes = %{state: :accepted}

        changes =
          if is_binary(actor_url), do: Map.put(changes, :actor_url, actor_url), else: changes

        relay |> Relay.changeset(changes) |> Repo.update()
        :ok
    end
  end

  @doc "Is `actor_url` an accepted relay? Gates firehose `Announce` ingestion."
  @spec relay_actor?(String.t() | nil) :: boolean()
  def relay_actor?(actor_url) when is_binary(actor_url) do
    Repo.exists?(from r in Relay, where: r.actor_url == ^actor_url and r.state == :accepted)
  end

  def relay_actor?(_), do: false

  ## Internals

  defp enqueue(verb, %Relay{} = relay) do
    RelayDeliver.enqueue(verb, %{
      relay_id: relay.id,
      inbox_url: relay.inbox_url,
      follow_activity_id: relay.follow_activity_id,
      object_url: relay.actor_url
    })
  end

  # Fetch the relay actor (signed with the instance actor — relays usually
  # require signed fetches) and read its inbox.
  defp discover_inbox(actor_url) do
    actor = InstanceActor.ensure!()

    case HTTP.fetch(actor_url, signed_with: {actor.key_id, actor.private_key_pem}) do
      {:ok, doc} ->
        case doc["inbox"] || get_in(doc, ["endpoints", "sharedInbox"]) do
          inbox when is_binary(inbox) -> {:ok, inbox}
          _ -> {:error, :no_inbox}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mint_follow_id do
    actor = InstanceActor.ensure!()

    actor.owner_url <>
      "#relay-follow-" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end
end
