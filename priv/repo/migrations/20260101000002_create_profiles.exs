defmodule Angler.Repo.Migrations.CreateProfiles do
  use Ecto.Migration

  def change do
    create table(:profiles, primary_key: false) do
      # snowflake; assigned by application
      add :id, :bigint, primary_key: true

      add :username, :citext, null: false
      add :domain, :citext
      add :name, :text
      add :bio, :text
      add :bio_text, :text
      add :website, :text
      add :location, :text
      add :is_private, :boolean, default: false, null: false
      add :discoverable, :boolean, default: true, null: false
      add :indexable_search, :boolean, default: true, null: false
      add :directory_opt_in, :boolean, default: false, null: false
      add :is_bot, :boolean, default: false, null: false
      add :is_suspended, :boolean, default: false, null: false
      add :status, :text

      add :avatar_path, :text
      add :header_path, :text

      add :public_key_pem, :text
      add :private_key_pem, :bytea
      add :inbox_url, :text
      add :outbox_url, :text
      add :shared_inbox_url, :text
      add :followers_url, :text
      add :following_url, :text
      add :remote_url, :text

      add :followers_count, :integer, default: 0, null: false
      add :following_count, :integer, default: 0, null: false
      add :statuses_count, :integer, default: 0, null: false

      add :last_status_at, :utc_datetime_usec
      add :last_fetched_at, :utc_datetime_usec
      add :last_active_at, :utc_datetime_usec

      add :moved_to_id, references(:profiles, on_delete: :nilify_all, type: :bigint)
      add :also_known_as, {:array, :text}, default: [], null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:profiles, [:username, :domain],
             nulls_distinct: false,
             name: :profiles_username_domain_idx
           )

    create unique_index(:profiles, [:remote_url], where: "remote_url IS NOT NULL")
    create index(:profiles, [:domain])
    create index(:profiles, [:is_suspended])

    create index(:profiles, [:directory_opt_in], where: "directory_opt_in = true")

    execute "CREATE INDEX profiles_username_trgm ON profiles USING gin (username gin_trgm_ops)",
            "DROP INDEX profiles_username_trgm"

    execute "CREATE INDEX profiles_name_trgm ON profiles USING gin (name gin_trgm_ops)",
            "DROP INDEX profiles_name_trgm"
  end
end
