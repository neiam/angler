defmodule Angler.Repo.Migrations.CreateBlocksMutes do
  use Ecto.Migration

  def change do
    create table(:profile_blocks) do
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :target_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:profile_blocks, [:profile_id, :target_id])
    create index(:profile_blocks, [:target_id])

    create table(:profile_mutes) do
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :target_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :hide_notifications, :boolean, null: false, default: true
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:profile_mutes, [:profile_id, :target_id])
  end
end
