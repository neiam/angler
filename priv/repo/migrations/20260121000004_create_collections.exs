defmodule Angler.Repo.Migrations.CreateCollections do
  use Ecto.Migration

  def change do
    create table(:collections, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :title, :string
      add :description, :text
      add :visibility, :string, null: false, default: "draft"
      add :published_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:collections, [:profile_id, "id DESC"])
    create index(:collections, [:visibility])

    create table(:collection_items) do
      add :collection_id, references(:collections, on_delete: :delete_all, type: :bigint),
        null: false

      add :status_id, references(:statuses, on_delete: :delete_all, type: :bigint), null: false
      add :position, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:collection_items, [:collection_id, :status_id])
    create index(:collection_items, [:collection_id, :position])
  end
end
