defmodule Angler.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    create table(:conversations, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :owner_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :participant_ids, {:array, :bigint}, null: false, default: []
      add :last_status_id, references(:statuses, on_delete: :nilify_all, type: :bigint)
      add :unread, :boolean, null: false, default: true
      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversations, [:owner_id, "id DESC"])
    create unique_index(:conversations, [:owner_id, :participant_ids])
  end
end
