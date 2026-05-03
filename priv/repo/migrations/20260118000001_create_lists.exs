defmodule Angler.Repo.Migrations.CreateLists do
  use Ecto.Migration

  def change do
    create table(:lists, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :title, :string, null: false
      add :replies_policy, :string, null: false, default: "list"
      add :exclusive, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:lists, [:profile_id, :id])

    create table(:list_accounts) do
      add :list_id, references(:lists, on_delete: :delete_all, type: :bigint), null: false
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:list_accounts, [:list_id, :profile_id])
    create index(:list_accounts, [:profile_id])
  end
end
