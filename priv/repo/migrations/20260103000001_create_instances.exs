defmodule Angler.Repo.Migrations.CreateInstances do
  use Ecto.Migration

  def change do
    create table(:instances) do
      add :domain, :citext, null: false
      add :software, :text
      add :version, :text
      add :description, :text
      add :open_registrations, :boolean, default: true, null: false
      add :user_count, :integer
      add :status_count, :integer
      add :nodeinfo, :jsonb

      # Moderation. nil/`noop` = silently allowed; `silence` hides public posts;
      # `suspend` rejects all activity from the domain.
      add :banned, :boolean, default: false, null: false
      add :ban_reason, :text
      add :ban_severity, :text
      add :reject_media, :boolean, default: false, null: false
      add :reject_reports, :boolean, default: false, null: false
      add :public_comments, :text
      add :private_comments, :text

      add :last_fetched_at, :utc_datetime_usec
      add :unreachable_since, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:instances, [:domain])
    create index(:instances, [:banned])
  end
end
