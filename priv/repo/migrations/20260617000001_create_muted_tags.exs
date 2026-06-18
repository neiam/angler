defmodule Angler.Repo.Migrations.CreateMutedTags do
  use Ecto.Migration

  def change do
    create table(:muted_tags) do
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :hashtag_id, references(:hashtags, on_delete: :delete_all), null: false
      add :filter_action, :string, null: false, default: "hide"
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:muted_tags, [:profile_id, :hashtag_id])
    create index(:muted_tags, [:hashtag_id])
  end
end
