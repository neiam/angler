defmodule Angler.Repo.Migrations.CreateCuratedRegisters do
  use Ecto.Migration

  # Curated registration applications and their admin/applicant message
  # thread (upstream curated_registers + curated_register_activities).
  def change do
    create table(:curated_registers) do
      add :email, :string, null: false
      add :username, :string, null: false
      add :password_hash, :string, null: false
      add :ip_address, :string
      add :verify_code_hash, :binary
      add :reason_to_join, :text
      add :is_approved, :boolean, null: false, default: false
      add :is_rejected, :boolean, null: false, default: false
      add :is_awaiting_more_info, :boolean, null: false, default: false
      add :user_has_responded, :boolean, null: false, default: false
      add :is_closed, :boolean, null: false, default: false
      add :approved_by_admin_id, references(:users, on_delete: :nilify_all)
      add :email_verified_at, :utc_datetime_usec
      add :action_taken_at, :utc_datetime_usec
      add :code_sent_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    # Only one open application per email/username; a closed (rejected)
    # applicant may apply again.
    create unique_index(:curated_registers, [:email],
             where: "is_closed = false",
             name: :curated_registers_open_email_index
           )

    create unique_index(:curated_registers, [:username],
             where: "is_closed = false",
             name: :curated_registers_open_username_index
           )

    create index(:curated_registers, [:is_closed, :email_verified_at])

    create table(:curated_register_activities) do
      add :register_id, references(:curated_registers, on_delete: :delete_all), null: false
      add :admin_id, references(:users, on_delete: :nilify_all)
      add :reply_to_id, references(:curated_register_activities, on_delete: :nilify_all)
      add :secret_code_hash, :binary
      add :type, :string, null: false
      add :message, :text
      add :from_admin, :boolean, null: false, default: false
      add :from_user, :boolean, null: false, default: false
      add :admin_only_view, :boolean, null: false, default: true
      add :action_required, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:curated_register_activities, [:register_id])
    create index(:curated_register_activities, [:reply_to_id])
  end
end
