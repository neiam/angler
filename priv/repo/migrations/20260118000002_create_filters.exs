defmodule Angler.Repo.Migrations.CreateFilters do
  use Ecto.Migration

  def change do
    create table(:filters, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :title, :string, null: false
      add :contexts, {:array, :string}, null: false, default: []
      add :filter_action, :string, null: false, default: "warn"
      add :expires_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:filters, [:profile_id, :id])

    create table(:filter_keywords, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :filter_id, references(:filters, on_delete: :delete_all, type: :bigint), null: false
      add :keyword, :string, null: false
      add :whole_word, :boolean, null: false, default: false
    end

    create index(:filter_keywords, [:filter_id])
  end
end
