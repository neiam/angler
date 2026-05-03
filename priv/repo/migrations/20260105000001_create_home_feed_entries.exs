defmodule Angler.Repo.Migrations.CreateHomeFeedEntries do
  use Ecto.Migration

  def change do
    create table(:home_feed_entries) do
      # `id` is bigserial (auto-incrementing) — gives us a monotonically
      # increasing cursor independent of the snowflake status_id, which is
      # what Mastodon's min_id/max_id semantics expect for the home timeline.
      add :profile_id,
          references(:profiles, on_delete: :delete_all, type: :bigint),
          null: false

      add :status_id,
          references(:statuses, on_delete: :delete_all, type: :bigint),
          null: false

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:home_feed_entries, [:profile_id, :status_id])
    create index(:home_feed_entries, [:profile_id, "id DESC"])
    create index(:home_feed_entries, [:status_id])
  end
end
