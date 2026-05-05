defmodule Angler.Repo.Migrations.CreateAdminInvites do
  use Ecto.Migration

  def change do
    create table(:admin_invites, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :invite_code, :string, null: false
      add :message, :text
      add :max_uses, :integer
      add :uses, :integer, default: 0, null: false
      add :expires_at, :utc_datetime_usec
      add :skip_email_verification, :boolean, default: false, null: false
      add :created_by_user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:admin_invites, [:invite_code])
  end
end
