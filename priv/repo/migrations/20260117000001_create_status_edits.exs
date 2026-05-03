defmodule Angler.Repo.Migrations.CreateStatusEdits do
  use Ecto.Migration

  def change do
    create table(:status_edits) do
      add :status_id, references(:statuses, on_delete: :delete_all, type: :bigint), null: false
      add :caption, :text
      add :rendered, :text
      add :spoiler_text, :text
      add :is_nsfw, :boolean, null: false, default: false
      add :media_attachments, :map, null: false, default: %{}
      add :poll, :map
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:status_edits, [:status_id, "id DESC"])
  end
end
