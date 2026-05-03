defmodule Angler.Repo.Migrations.CreateStatusAssociations do
  use Ecto.Migration

  def change do
    create table(:mentions) do
      add :status_id, references(:statuses, on_delete: :delete_all, type: :bigint), null: false
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :silent, :boolean, default: false, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:mentions, [:status_id, :profile_id])
    create index(:mentions, [:profile_id, :inserted_at])

    create table(:status_hashtags) do
      add :status_id, references(:statuses, on_delete: :delete_all, type: :bigint), null: false
      add :hashtag_id, references(:hashtags, on_delete: :delete_all), null: false
      add :profile_id, :bigint, null: false
      add :status_visibility, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:status_hashtags, [:status_id, :hashtag_id])
    create index(:status_hashtags, [:hashtag_id, "status_id DESC"])

    create table(:likes) do
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :status_id, references(:statuses, on_delete: :delete_all, type: :bigint), null: false
      add :remote_url, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:likes, [:profile_id, :status_id])
    create unique_index(:likes, [:remote_url], where: "remote_url IS NOT NULL")
    create index(:likes, [:status_id])

    create table(:reblogs) do
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :status_id, references(:statuses, on_delete: :delete_all, type: :bigint), null: false
      add :reblog_status_id, references(:statuses, on_delete: :nilify_all, type: :bigint)
      add :remote_url, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:reblogs, [:profile_id, :status_id])
    create unique_index(:reblogs, [:remote_url], where: "remote_url IS NOT NULL")
    create index(:reblogs, [:status_id])
  end
end
