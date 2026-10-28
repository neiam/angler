defmodule Angler.Repo.Migrations.AddBlockSyncToInstances do
  use Ecto.Migration

  # FEP-070c block sync (upstream 2026_09_30_042509). `block_sync_url` is the
  # peer's advertised endpoint, pulled daily; the other two stand in for
  # upstream's cache keys (failure back-off, reconcile cursor).
  def change do
    alter table(:instances) do
      add :block_sync_url, :string
      add :block_sync_backoff_until, :utc_datetime_usec
      add :block_sync_queued_at, :utc_datetime_usec
    end

    create index(:instances, [:block_sync_queued_at],
             where: "block_sync_url IS NOT NULL AND banned = false"
           )
  end
end
