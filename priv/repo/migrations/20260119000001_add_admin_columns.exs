defmodule Angler.Repo.Migrations.AddAdminColumns do
  use Ecto.Migration

  def change do
    # Reports moderation state.
    alter table(:reports) do
      add :assigned_account_id, references(:profiles, on_delete: :nilify_all, type: :bigint)
      add :action_taken, :boolean, null: false, default: false
      add :action_taken_at, :utc_datetime_usec

      add :action_taken_by_account_id,
          references(:profiles, on_delete: :nilify_all, type: :bigint)

      add :moderator_comment, :text
    end

    create index(:reports, [:assigned_account_id])
    create index(:reports, [:action_taken, "id DESC"])

    # Per-action moderation log against an account (Mastodon "AccountWarning"
    # shape — reused for suspend/silence/disable/sensitive bookkeeping).
    create table(:account_actions) do
      add :target_account_id, references(:profiles, on_delete: :delete_all, type: :bigint),
        null: false

      add :moderator_account_id, references(:profiles, on_delete: :nilify_all, type: :bigint)
      add :report_id, references(:reports, on_delete: :nilify_all, type: :bigint)
      add :action, :string, null: false
      add :text, :text
      add :send_email_notification, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:account_actions, [:target_account_id, "id DESC"])
  end
end
