defmodule Angler.Repo.Migrations.CreateStatusArchivedSnapshots do
  use Ecto.Migration

  def change do
    create table(:status_archived_snapshots, primary_key: false) do
      add :status_id, references(:statuses, on_delete: :delete_all, type: :bigint),
        primary_key: true

      add :original_scope, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end
end
