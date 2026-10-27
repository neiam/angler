defmodule Angler.Repo.Migrations.CreateStatusIdempotencyKeys do
  use Ecto.Migration

  def change do
    # One row per (user, Idempotency-Key) on POST /api/v1/statuses. status_id
    # is null while the request is in flight.
    create table(:status_idempotency_keys) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :key_hash, :binary, null: false
      add :status_id, :bigint
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:status_idempotency_keys, [:user_id, :key_hash])
    create index(:status_idempotency_keys, [:inserted_at])
  end
end
