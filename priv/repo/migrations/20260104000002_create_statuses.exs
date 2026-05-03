defmodule Angler.Repo.Migrations.CreateStatuses do
  use Ecto.Migration

  def change do
    create table(:statuses, primary_key: false) do
      # snowflake; assigned by the application
      add :id, :bigint, primary_key: true

      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false

      add :caption, :text
      add :rendered, :text
      add :is_nsfw, :boolean, default: false, null: false
      add :cw_summary, :text
      add :visibility, :text, null: false
      add :scope, :text
      add :type, :text
      add :pf_type, :text
      add :local, :boolean, default: true, null: false
      add :uri, :text
      add :url, :text

      add :in_reply_to_id, references(:statuses, on_delete: :nilify_all, type: :bigint)

      add :in_reply_to_profile_id,
          references(:profiles, on_delete: :nilify_all, type: :bigint)

      add :reblog_of_id, references(:statuses, on_delete: :delete_all, type: :bigint)

      add :language, :text, default: "en", null: false
      add :comments_disabled, :boolean, default: false, null: false

      add :reply_count, :integer, default: 0, null: false
      add :reblogs_count, :integer, default: 0, null: false
      add :likes_count, :integer, default: 0, null: false

      add :edited_at, :utc_datetime_usec
      add :deleted_at, :utc_datetime_usec
      add :scheduled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:statuses, [:profile_id, "id DESC"], where: "deleted_at IS NULL")
    create index(:statuses, [:in_reply_to_id], where: "deleted_at IS NULL")
    create index(:statuses, [:reblog_of_id], where: "deleted_at IS NULL")
    create unique_index(:statuses, [:uri], where: "uri IS NOT NULL")
    create index(:statuses, [:visibility, "id DESC"], where: "deleted_at IS NULL")
  end
end
