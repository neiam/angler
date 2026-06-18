defmodule Angler.Repo.Migrations.CreateWebauthnCredentials do
  use Ecto.Migration

  def change do
    create table(:webauthn_credentials) do
      add :user_id, references(:users, on_delete: :delete_all, type: :bigint), null: false
      add :credential_id, :binary, null: false
      add :public_key, :binary, null: false
      add :sign_count, :bigint, null: false, default: 0
      add :aaguid, :uuid
      add :name, :string, size: 100
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:webauthn_credentials, [:user_id, :credential_id],
             name: :webauthn_credentials_user_credential_index
           )
  end
end
