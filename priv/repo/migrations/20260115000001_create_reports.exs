defmodule Angler.Repo.Migrations.CreateReports do
  use Ecto.Migration

  def change do
    create table(:reports, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :user_id, references(:users, on_delete: :delete_all, type: :bigint), null: false
      add :object_id, :bigint, null: false
      add :object_type, :string, null: false
      add :reported_profile_id, :bigint
      add :type, :string, null: false
      add :resolved_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:reports, [:user_id, :object_type, :object_id])
    create index(:reports, [:reported_profile_id])
  end
end
