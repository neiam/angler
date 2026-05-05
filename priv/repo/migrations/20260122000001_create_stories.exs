defmodule Angler.Repo.Migrations.CreateStories do
  use Ecto.Migration

  def change do
    create table(:stories, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :type, :string, null: false
      add :mime, :string, null: false
      add :path, :text, null: false
      add :duration_ms, :integer, null: false, default: 3000
      add :can_reply, :boolean, null: false, default: true
      add :can_react, :boolean, null: false, default: true
      add :active, :boolean, null: false, default: false
      add :view_count, :integer, null: false, default: 0
      add :local, :boolean, null: false, default: true
      add :remote_url, :text
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:stories, [:profile_id, "id DESC"])
    create index(:stories, [:active, :expires_at])

    create table(:story_views) do
      add :story_id, references(:stories, on_delete: :delete_all, type: :bigint), null: false
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:story_views, [:story_id, :profile_id])
    create index(:story_views, [:profile_id])
  end
end
