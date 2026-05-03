defmodule Angler.Repo.Migrations.CreateBookmarks do
  use Ecto.Migration

  def change do
    create table(:bookmarks) do
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :status_id, references(:statuses, on_delete: :delete_all, type: :bigint), null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:bookmarks, [:profile_id, :status_id])
    create index(:bookmarks, [:profile_id, "id DESC"])
  end
end
