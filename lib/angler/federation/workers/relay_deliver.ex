defmodule Angler.Federation.Workers.RelayDeliver do
  @moduledoc """
  Outbound deliverer for relay subscription activities, signed by the
  **instance actor** (not a user).

  Verbs:

    * `:follow` — `Follow` of the relay actor (LitePub model) sent to its inbox
      to subscribe.
    * `:undo` — `Undo` of that `Follow` to unsubscribe.

  Args: `relay_id`, `inbox_url`, `follow_activity_id`, `object_url` (the relay
  actor). See `Angler.Federation.Relays`.
  """

  use Oban.Worker,
    queue: :federation_outbound,
    max_attempts: 8

  require Logger

  alias Angler.Federation.Activity
  alias Angler.Federation.HTTPSignature
  alias Angler.Federation.InstanceActor
  alias Angler.Repo

  @context "https://www.w3.org/ns/activitystreams"

  @spec enqueue(:follow | :undo, map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(verb, args) when verb in [:follow, :undo] and is_map(args) do
    %{"verb" => Atom.to_string(verb)}
    |> Map.merge(stringify_keys(args))
    |> __MODULE__.new(unique: unique_opts())
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "verb" => "follow",
          "inbox_url" => inbox_url,
          "follow_activity_id" => fid,
          "object_url" => object_url
        }
      }) do
    actor = InstanceActor.ensure!()

    deliver(actor, inbox_url, %{
      "@context" => @context,
      "id" => fid,
      "type" => "Follow",
      "actor" => actor.owner_url,
      "object" => object_url
    })
  end

  def perform(%Oban.Job{
        args: %{
          "verb" => "undo",
          "inbox_url" => inbox_url,
          "follow_activity_id" => fid,
          "object_url" => object_url
        }
      }) do
    actor = InstanceActor.ensure!()

    deliver(actor, inbox_url, %{
      "@context" => @context,
      "id" => fid <> "/undo",
      "type" => "Undo",
      "actor" => actor.owner_url,
      "object" => %{
        "id" => fid,
        "type" => "Follow",
        "actor" => actor.owner_url,
        "object" => object_url
      }
    })
  end

  defp deliver(actor, inbox_url, activity) do
    body = Jason.encode!(activity)
    uri = URI.parse(inbox_url)

    {:ok, headers} =
      HTTPSignature.sign(
        :post,
        uri.path || "/inbox",
        uri.host,
        body,
        actor.key_id,
        actor.private_key_pem,
        [{"Content-Type", "application/activity+json"}, {"Accept", "application/activity+json"}]
      )

    case Req.post(
           [url: inbox_url, headers: headers, body: body, retry: false, receive_timeout: 10_000]
           |> Keyword.merge(req_overrides())
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        log(:delivered, activity, actor, inbox_url, body)
        :ok

      {:ok, %{status: status}} when status in 400..499 ->
        log(:rejected, activity, actor, inbox_url, body, "remote #{status}")
        :ok

      {:ok, %{status: status}} ->
        log(:error, activity, actor, inbox_url, body, "remote #{status}")
        {:error, "remote #{status}"}

      {:error, reason} ->
        log(:error, activity, actor, inbox_url, body, inspect(reason))
        {:error, reason}
    end
  end

  defp log(status, activity, actor, inbox_url, body, error \\ nil) do
    Activity.changeset(%{
      direction: :outbound,
      activity_id: activity["id"],
      activity_type: activity["type"],
      actor_url: actor.owner_url,
      target_inbox: inbox_url,
      raw_body: body,
      status: status,
      error: error,
      delivered_at: if(status == :delivered, do: DateTime.utc_now())
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  defp unique_opts do
    [period: 60, fields: [:args], keys: [:verb, :follow_activity_id, :inbox_url]]
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp req_overrides, do: Application.get_env(:angler, :req_options, [])
end
