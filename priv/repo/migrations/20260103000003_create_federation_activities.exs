defmodule Angler.Repo.Migrations.CreateFederationActivities do
  use Ecto.Migration

  def change do
    create table(:federation_activities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :direction, :text, null: false
      add :activity_id, :text
      add :activity_type, :text
      add :actor_url, :text
      add :object_type, :text
      add :object_id, :text
      add :target_inbox, :text
      add :payload, :jsonb
      add :raw_body, :bytea
      add :status, :text, null: false, default: "pending"
      add :error, :text
      add :delivered_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    # Inbound idempotency: re-deliveries of the same activity by the same
    # actor are no-ops on insert conflict. Per-week dedup once we partition.
    create unique_index(:federation_activities, [:direction, :activity_id, :actor_url],
             name: :federation_activities_dedup_idx,
             nulls_distinct: false
           )

    create index(:federation_activities, [:direction, :inserted_at])
    create index(:federation_activities, [:status])
  end
end
