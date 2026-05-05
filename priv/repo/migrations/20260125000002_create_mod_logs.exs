defmodule Angler.Repo.Migrations.CreateModLogs do
  use Ecto.Migration

  def change do
    create table(:mod_logs, primary_key: false) do
      add :id, :bigint, primary_key: true
      # Acting moderator (User.id). Always set on local actions.
      add :actor_user_id, references(:users, on_delete: :nilify_all), null: false

      # The thing being acted on. Free-form so we can target users,
      # statuses, reports, instances, etc.
      add :object_type, :string, null: false
      add :object_id, :bigint
      add :object_uid, :bigint

      add :action, :string, null: false
      add :access_level, :string, default: "moderator", null: false
      add :metadata, :jsonb, default: "{}"

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:mod_logs, [:actor_user_id, :id])
    create index(:mod_logs, [:object_type, :object_id])
    create index(:mod_logs, [:action])
  end
end
