defmodule Angler.Repo.Migrations.BoostsInTimelines do
  @moduledoc """
  Boosts show in timelines as Mastodon-style wrappers, rendered from the
  reblog itself rather than from a synthetic status row.

  * `reblogs.reblog_status_id` becomes the wrapper's id: a snowflake of its
    own, so no longer a reference to `statuses`. Existing boosts get one
    from their timestamp (node bits 1023 and the row id as the sequence,
    so they can't collide with each other or with ids minted live).
  * `home_feed_entries.reblog_id` records which boost put a post in a feed.
  """

  use Ecto.Migration

  # Angler.Snowflake's default epoch, 2020-01-01 UTC.
  @epoch_ms 1_577_836_800_000

  def up do
    execute("ALTER TABLE reblogs DROP CONSTRAINT IF EXISTS reblogs_reblog_status_id_fkey")

    execute("""
    UPDATE reblogs
       SET reblog_status_id =
             (((extract(epoch FROM inserted_at) * 1000)::bigint - #{@epoch_ms}) << 22)
             | (1023 << 12) | (id & 4095)
     WHERE reblog_status_id IS NULL
    """)

    create unique_index(:reblogs, [:reblog_status_id])

    alter table(:home_feed_entries) do
      add :reblog_id, references(:reblogs, on_delete: :delete_all)
    end

    create index(:home_feed_entries, [:reblog_id])
  end

  def down do
    alter table(:home_feed_entries) do
      remove :reblog_id
    end

    drop unique_index(:reblogs, [:reblog_status_id])
    execute("UPDATE reblogs SET reblog_status_id = NULL")

    execute("""
    ALTER TABLE reblogs ADD CONSTRAINT reblogs_reblog_status_id_fkey
      FOREIGN KEY (reblog_status_id) REFERENCES statuses(id) ON DELETE SET NULL
    """)
  end
end
