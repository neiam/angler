defmodule Angler.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :citext, null: false
      add :email_verified_at, :utc_datetime_usec
      add :password_hash, :text, null: false
      add :name, :text
      add :language, :text, default: "en", null: false
      add :timezone, :text, default: "UTC", null: false
      add :is_admin, :boolean, default: false, null: false
      add :is_moderator, :boolean, default: false, null: false
      # nil = active. "deleted" / "suspended" hide the user from public surfaces.
      add :status, :text
      add :last_active_at, :utc_datetime_usec

      add :two_factor_secret_enc, :bytea
      add :two_factor_recovery_enc, :bytea
      add :two_factor_enabled_at, :utc_datetime_usec

      add :register_source, :text
      # IP fields are stored as text for now; we can swap to PG `inet` later
      # via a custom Ecto type without changing application code.
      add :register_ip, :text

      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:profile_id])
    create index(:users, [:status])
  end
end
