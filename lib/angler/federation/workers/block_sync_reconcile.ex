defmodule Angler.Federation.Workers.BlockSyncReconcile do
  @moduledoc """
  Daily (cron, 03:40) FEP-070c pull, as upstream's
  `federation:block-sync-reconcile`: queues `Workers.BlockSync` for up to
  `reconcile_limit` peers that have advertised a block sync endpoint,
  spread over the next hour. Peers are taken least recently queued first,
  so a limit smaller than the peer count works through them in turn.
  Banned, suspended and unreachable peers, and endpoints not on the peer's
  own host, are skipped.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query, warn: false

  alias Angler.Admin
  alias Angler.Federation.{Bans, BlockSync, Instance, Sync}
  alias Angler.Federation.Workers.BlockSync, as: SyncWorker
  alias Angler.Repo

  @spread_s 3600

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if BlockSync.receiving?() do
      limit = args["limit"] || BlockSync.reconcile_limit()
      spread = args["spread"] || @spread_s

      peers =
        Repo.all(
          from i in Instance,
            where: not is_nil(i.block_sync_url) and i.banned == false,
            order_by: [asc_nulls_first: i.block_sync_queued_at, asc: i.id],
            limit: ^limit
        )

      Enum.each(peers, &queue(&1, spread))

      from(i in Instance, where: i.id in ^Enum.map(peers, & &1.id))
      |> Repo.update_all(set: [block_sync_queued_at: DateTime.utc_now()])
    end

    :ok
  end

  defp queue(%Instance{domain: domain, block_sync_url: url} = instance, spread) do
    authority = Sync.authority(url)
    domain = String.downcase(domain)

    if authority != nil and Sync.host(authority) == domain and is_nil(instance.unreachable_since) and
         not Bans.banned?(domain) and not Admin.instance_suspended?(domain) do
      delay = if spread > 0, do: :rand.uniform(spread + 1) - 1, else: 0
      {:ok, _} = SyncWorker.enqueue_periodic(authority, url, delay)
    end
  end
end
