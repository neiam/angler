defmodule Angler.Repo.Migrations.CreateHashtags do
  use Ecto.Migration

  def change do
    create table(:hashtags) do
      add :name, :citext, null: false
      add :slug, :citext, null: false
      add :usage_count, :integer, default: 0, null: false
      add :disabled, :boolean, default: false, null: false
      add :nsfw, :boolean, default: false, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:hashtags, [:name])
    create unique_index(:hashtags, [:slug])
    create index(:hashtags, [:disabled])

    execute "CREATE INDEX hashtags_name_trgm ON hashtags USING gin (name gin_trgm_ops)",
            "DROP INDEX hashtags_name_trgm"
  end
end
