defmodule Angler.Federation.Workers.BlockSync do
  @moduledoc """
  Runs `Angler.Federation.BlockSync.synchronize/4` for a peer, as upstream's
  BlockSyncPipeline. Queued when a peer's signed digest disagrees with ours
  (unique per peer for the cooldown, later headers updating the pending
  job's digest) or by the daily `BlockSyncReconcile` (unique for 90
  minutes). Gives remote fetches 90 seconds; a failed fetch holds off
  header-driven syncs of that peer for six hours.
  """

  use Oban.Worker, queue: :federation_inbound, max_attempts: 1

  import Ecto.Query, warn: false

  require Logger

  alias Angler.Federation.{BlockSync, Instance, Sync}
  alias Angler.Repo

  @remote_budget_ms 90_000

  @doc "Queue a header-driven sync, expecting `digest`."
  @spec enqueue(String.t(), String.t(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(authority, url, digest) do
    %{"authority" => authority, "url" => url, "digest" => digest, "periodic" => false}
    |> new(
      unique: [
        period: BlockSync.cooldown(),
        fields: [:args],
        keys: [:authority, :periodic],
        states: [:available, :scheduled, :executing, :retryable, :completed]
      ],
      replace: [available: [:args], scheduled: [:args]]
    )
    |> Oban.insert()
  end

  @doc "Queue the daily pull of a peer, `delay` seconds from now."
  @spec enqueue_periodic(String.t(), String.t(), non_neg_integer()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_periodic(authority, url, delay) do
    %{"authority" => authority, "url" => url, "digest" => nil, "periodic" => true}
    |> new(
      schedule_in: delay,
      unique: [
        period: 5400,
        fields: [:args],
        keys: [:authority, :periodic],
        states: [:available, :scheduled, :executing, :retryable, :completed]
      ]
    )
    |> Oban.insert()
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(120)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"authority" => authority, "url" => url} = args}) do
    unless unreachable?(authority) do
      deadline = System.monotonic_time(:millisecond) + @remote_budget_ms

      try do
        case BlockSync.synchronize(authority, url, args["digest"], deadline) do
          %{status: :fetch_failed} -> BlockSync.back_off(authority)
          _ -> :ok
        end
      rescue
        e ->
          Logger.warning("BlockSync: synchronization of #{authority} failed: #{inspect(e)}")
          BlockSync.back_off(authority)
      end
    end

    :ok
  end

  defp unreachable?(authority) do
    case Sync.host(authority) do
      host when is_binary(host) ->
        Repo.exists?(
          from i in Instance, where: i.domain == ^host and not is_nil(i.unreachable_since)
        )

      _ ->
        false
    end
  end
end
