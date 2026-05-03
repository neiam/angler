defmodule Angler.Repo.Migrations.CreatePinnedStatuses do
  use Ecto.Migration

  def change do
    create table(:pinned_statuses) do
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :status_id, references(:statuses, on_delete: :delete_all, type: :bigint), null: false
      add :position, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pinned_statuses, [:profile_id, :status_id])
    create index(:pinned_statuses, [:profile_id, :position])
  end
end
