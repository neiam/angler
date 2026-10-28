defmodule Angler.Federation.Workers.FollowDeliver do
  @moduledoc """
  Outbound deliverer for follow-lifecycle activities.

  Supported verbs:

  * `:accept` — sent in response to an inbound `Follow` against an unlocked
    local user. Args: `local_actor_id`, `inbox_url`, `follow_activity_id`,
    `follow_actor_url` (the original Follow's actor).
  * `:follow` — sent when a local user POSTs `/accounts/:id/follow` against
    a remote target. Args: `local_actor_id`, `inbox_url`,
    `follow_activity_id` (the id we minted up front; matches the
    `Follower` row's `remote_url`), `target_actor_url`.
  * `:undo` — sent when a local user unfollows a remote target. Same args
    as `:follow`.
  * `:reject` — TODO; documented for completeness.

  See plans/federation/queues/follow_activity_pub_deliver.md.
  """

  use Oban.Worker,
    queue: :federation_outbound,
    max_attempts: 8

  require Logger

  alias Angler.Federation.Activity
  alias Angler.Federation.HTTPSignature
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo

  @doc "Enqueue an outbound follow-lifecycle activity."
  @spec enqueue(:accept | :reject | :follow | :undo, map()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(verb, args) when verb in [:accept, :reject, :follow, :undo] and is_map(args) do
    %{"verb" => Atom.to_string(verb)}
    |> Map.merge(stringify_keys(args))
    |> __MODULE__.new(unique: unique_opts())
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"verb" => "accept"} = args}) do
    deliver_accept(args)
  end

  def perform(%Oban.Job{args: %{"verb" => "follow"} = args}) do
    deliver_follow(args)
  end

  def perform(%Oban.Job{args: %{"verb" => "undo"} = args}) do
    deliver_undo(args)
  end

  def perform(%Oban.Job{args: %{"verb" => "reject"} = args}) do
    deliver_reject(args)
  end

  def perform(%Oban.Job{args: %{"verb" => verb} = args}) do
    Logger.warning("FollowDeliver verb=#{verb} not yet implemented; args=#{inspect(args)}")
    :ok
  end

  ## Accept

  defp deliver_accept(%{
         "local_actor_id" => local_actor_id,
         "inbox_url" => inbox_url,
         "follow_activity_id" => follow_activity_id,
         "follow_actor_url" => follow_actor_url
       }) do
    actor = Repo.get!(Profile, local_actor_id)
    activity = build_accept(actor, follow_activity_id, follow_actor_url)
    body = Jason.encode!(activity)
    deliver(actor, inbox_url, body, activity["id"], "Accept")
  end

  defp build_accept(%Profile{} = actor, follow_activity_id, follow_actor_url) do
    actor_url = Profiles.actor_url(actor)

    accept_id =
      actor_url <> "/accepts/" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => accept_id,
      "type" => "Accept",
      "actor" => actor_url,
      "object" => %{
        "id" => follow_activity_id,
        "type" => "Follow",
        "actor" => follow_actor_url,
        "object" => actor_url
      }
    }
  end

  ## Reject (outbound)

  defp deliver_reject(%{
         "local_actor_id" => local_actor_id,
         "inbox_url" => inbox_url,
         "follow_activity_id" => follow_activity_id,
         "follow_actor_url" => follow_actor_url
       }) do
    actor = Repo.get!(Profile, local_actor_id)
    actor_url = Profiles.actor_url(actor)

    reject_id =
      actor_url <> "/rejects/" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    activity = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => reject_id,
      "type" => "Reject",
      "actor" => actor_url,
      "object" => %{
        "id" => follow_activity_id,
        "type" => "Follow",
        "actor" => follow_actor_url,
        "object" => actor_url
      }
    }

    body = Jason.encode!(activity)
    deliver(actor, inbox_url, body, activity["id"], "Reject")
  end

  ## Follow (outbound)

  defp deliver_follow(%{
         "local_actor_id" => local_actor_id,
         "inbox_url" => inbox_url,
         "follow_activity_id" => follow_activity_id,
         "target_actor_url" => target_actor_url
       }) do
    actor = Repo.get!(Profile, local_actor_id)
    actor_url = Profiles.actor_url(actor)

    activity = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => follow_activity_id,
      "type" => "Follow",
      "actor" => actor_url,
      "object" => target_actor_url
    }

    body = Jason.encode!(activity)
    deliver(actor, inbox_url, body, activity["id"], "Follow")
  end

  ## Undo Follow (outbound)

  defp deliver_undo(%{
         "local_actor_id" => local_actor_id,
         "inbox_url" => inbox_url,
         "follow_activity_id" => follow_activity_id,
         "target_actor_url" => target_actor_url
       }) do
    actor = Repo.get!(Profile, local_actor_id)
    actor_url = Profiles.actor_url(actor)

    undo_id =
      actor_url <> "/undos/" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    activity = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => undo_id,
      "type" => "Undo",
      "actor" => actor_url,
      # No id when undoing a follow we have no record of (followers sync).
      "object" =>
        %{
          "id" => follow_activity_id,
          "type" => "Follow",
          "actor" => actor_url,
          "object" => target_actor_url
        }
        |> Map.reject(fn {_, v} -> is_nil(v) end)
    }

    body = Jason.encode!(activity)
    deliver(actor, inbox_url, body, activity["id"], "Undo")
  end

  defp deliver(%Profile{} = actor, inbox_url, body, activity_id, activity_type) do
    uri = URI.parse(inbox_url)
    actor_url = Profiles.actor_url(actor)

    {:ok, headers} =
      HTTPSignature.sign(
        :post,
        uri.path || "/inbox",
        uri.host,
        body,
        actor_url <> "#main-key",
        actor.private_key_pem,
        [{"Content-Type", "application/activity+json"}, {"Accept", "application/activity+json"}]
      )

    case Angler.Federation.HTTP.deliver(
           [
             url: inbox_url,
             headers: headers,
             body: body,
             retry: false,
             receive_timeout: 10_000
           ]
           |> Keyword.merge(req_overrides())
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        log_outbound(:delivered, activity_id, activity_type, actor_url, inbox_url, body)
        :ok

      {:ok, %{status: 410}} ->
        log_outbound(
          :rejected,
          activity_id,
          activity_type,
          actor_url,
          inbox_url,
          body,
          "remote 410 gone"
        )

        :ok

      {:ok, %{status: status}} when status in 400..499 ->
        log_outbound(
          :rejected,
          activity_id,
          activity_type,
          actor_url,
          inbox_url,
          body,
          "remote #{status}"
        )

        # Don't retry on 4xx (other than 408/429 which we don't special-case yet).
        :ok

      {:ok, %{status: status}} ->
        log_outbound(
          :error,
          activity_id,
          activity_type,
          actor_url,
          inbox_url,
          body,
          "remote #{status}"
        )

        {:error, "remote #{status}"}

      {:error, :host_unavailable} ->
        {:cancel, :host_unavailable}

      {:error, reason} ->
        log_outbound(
          :error,
          activity_id,
          activity_type,
          actor_url,
          inbox_url,
          body,
          inspect(reason)
        )

        {:error, reason}
    end
  end

  defp log_outbound(status, activity_id, activity_type, actor_url, inbox_url, body, error \\ nil) do
    Activity.changeset(%{
      direction: :outbound,
      activity_id: activity_id,
      activity_type: activity_type,
      actor_url: actor_url,
      target_inbox: inbox_url,
      raw_body: body,
      status: status,
      error: error,
      delivered_at: if(status == :delivered, do: DateTime.utc_now())
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  defp unique_opts do
    # `verb` is part of the key so a Follow + Undo (or Accept + Reject) for the
    # same activity_id+inbox don't collide on Oban-level dedup.
    [
      period: 60,
      fields: [:args],
      keys: [:verb, :follow_activity_id, :inbox_url]
    ]
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp req_overrides do
    Application.get_env(:angler, :req_options, [])
  end
end
