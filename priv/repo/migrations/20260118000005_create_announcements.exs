defmodule Angler.Repo.Migrations.CreateAnnouncements do
  use Ecto.Migration

  def change do
    create table(:announcements, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :text, :text, null: false
      add :published, :boolean, null: false, default: false
      add :all_day, :boolean, null: false, default: false
      add :starts_at, :utc_datetime_usec
      add :ends_at, :utc_datetime_usec
      add :published_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:announcements, [:published, "id DESC"])

    create table(:announcement_dismissals) do
      add :announcement_id, references(:announcements, on_delete: :delete_all, type: :bigint),
        null: false

      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:announcement_dismissals, [:announcement_id, :profile_id])
  end
end
