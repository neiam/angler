defmodule Angler.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    create table(:notifications) do
      add :recipient_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :account_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :type, :string, null: false
      add :status_id, references(:statuses, on_delete: :delete_all, type: :bigint)
      add :dismissed, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    # Idempotency: one notification per (recipient, type, account, status).
    # NULLS NOT DISTINCT (PG15+) so follow notifications (status_id = NULL)
    # also dedupe.
    execute(
      """
      CREATE UNIQUE INDEX notifications_dedup_idx
      ON notifications (recipient_id, type, account_id, status_id)
      NULLS NOT DISTINCT
      """,
      "DROP INDEX notifications_dedup_idx"
    )

    # Timeline query: recipient's most-recent undismissed notifications.
    create index(:notifications, [:recipient_id, "id DESC"], where: "dismissed = false")
  end
end
