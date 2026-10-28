defmodule Angler.Federation.Workers.BlockDeliver do
  @moduledoc """
  Sends `Block` or `Undo Block` to a remote actor a local profile blocked or
  unblocked (FEP-070c disclosure), as upstream's DeliverBlockActivity.

  One pending job per pair; by the time it runs the block may have been
  lifted (or put back), and it then sends nothing. A failed delivery is
  retried after five minutes, then an hour.
  """

  use Oban.Worker,
    queue: :federation_outbound,
    max_attempts: 3,
    unique: [
      period: 7200,
      fields: [:args],
      keys: [:blocker_id, :blocked_id],
      states: [:available, :scheduled]
    ]

  alias Angler.Federation.{Activity, BlockSync, HTTPSignature}
  alias Angler.Profiles
  alias Angler.Profiles.{Block, Profile}
  alias Angler.Repo

  @retry_delays [300, 3600]

  @spec enqueue(integer(), integer(), integer(), boolean()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(blocker_id, blocked_id, block_id, undo?) do
    %{
      "blocker_id" => blocker_id,
      "blocked_id" => blocked_id,
      "block_id" => block_id,
      "undo" => undo?
    }
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: Enum.at(@retry_delays, attempt - 1, List.last(@retry_delays))

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"blocker_id" => blocker_id, "blocked_id" => blocked_id} = args}) do
    undo? = args["undo"] == true

    with true <- BlockSync.disclosing?(),
         %Profile{domain: nil, status: nil, private_key_pem: pem} = blocker when is_binary(pem) <-
           Repo.get(Profile, blocker_id),
         %Profile{domain: d, inbox_url: inbox} = blocked when is_binary(d) and is_binary(inbox) <-
           Repo.get(Profile, blocked_id) do
      case {Repo.get_by(Block, profile_id: blocker_id, target_id: blocked_id), undo?} do
        {%Block{id: id}, false} -> deliver(blocker, blocked, activity(blocker, blocked, id))
        {nil, true} -> deliver(blocker, blocked, undo(blocker, blocked, args["block_id"]))
        # Changed again since this was queued.
        _ -> :ok
      end
    else
      _ -> :ok
    end
  end

  defp activity(blocker, blocked, block_id) do
    Map.put(
      object(blocker, blocked, block_id),
      "@context",
      "https://www.w3.org/ns/activitystreams"
    )
  end

  defp undo(blocker, blocked, block_id) do
    actor_url = Profiles.actor_url(blocker)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{actor_url}#blocks/#{block_id}/undo",
      "type" => "Undo",
      "actor" => actor_url,
      "object" => object(blocker, blocked, block_id)
    }
  end

  defp object(blocker, blocked, block_id) do
    actor_url = Profiles.actor_url(blocker)

    %{
      "id" => "#{actor_url}#blocks/#{block_id}",
      "type" => "Block",
      "actor" => actor_url,
      "object" => blocked.remote_url
    }
  end

  defp deliver(blocker, blocked, activity) do
    body = Jason.encode!(activity)
    inbox_url = blocked.inbox_url
    uri = URI.parse(inbox_url)
    actor_url = Profiles.actor_url(blocker)

    {:ok, headers} =
      HTTPSignature.sign(
        :post,
        uri.path || "/inbox",
        uri.host,
        body,
        actor_url <> "#main-key",
        blocker.private_key_pem,
        [
          {"Content-Type", "application/activity+json"},
          {"Accept", "application/activity+json"}
        ] ++ BlockSync.headers(inbox_url)
      )

    result =
      Angler.Federation.HTTP.deliver(
        url: inbox_url,
        headers: headers,
        body: body,
        retry: false,
        receive_timeout: 10_000
      )

    {status, error, reply} =
      case result do
        {:ok, %{status: code}} when code in 200..299 ->
          {:delivered, nil, :ok}

        {:ok, %{status: code}} when code in 400..499 ->
          {:rejected, "remote #{code}", :ok}

        {:ok, %{status: code}} ->
          {:error, "remote #{code}", {:error, "remote #{code}"}}

        # Backed off (DeliveryHosts): a clean skip, as the other deliverers.
        {:error, :host_unavailable} ->
          {:rejected, "host unavailable", {:cancel, :host_unavailable}}

        {:error, reason} ->
          {:error, inspect(reason), {:error, reason}}
      end

    Activity.changeset(%{
      direction: :outbound,
      activity_id: activity["id"],
      activity_type: activity["type"],
      actor_url: actor_url,
      target_inbox: inbox_url,
      raw_body: body,
      status: status,
      error: error,
      delivered_at: if(status == :delivered, do: DateTime.utc_now())
    })
    |> Repo.insert(on_conflict: :nothing)

    reply
  end
end
