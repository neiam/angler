defmodule Angler.Repo.Migrations.CreateFollowedTags do
  use Ecto.Migration

  def change do
    create table(:followed_tags) do
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :hashtag_id, references(:hashtags, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:followed_tags, [:profile_id, :hashtag_id])
    create index(:followed_tags, [:hashtag_id])
  end
end
