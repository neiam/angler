defmodule Angler.Repo.Migrations.CreateOauthAuthorizationCodes do
  use Ecto.Migration

  def change do
    create table(:oauth_authorization_codes) do
      add :code_hash, :bytea, null: false

      add :client_id, references(:oauth_clients, on_delete: :delete_all, type: :bigint),
        null: false

      add :user_id, references(:users, on_delete: :delete_all, type: :bigint), null: false
      add :scopes, {:array, :text}, null: false, default: []
      add :redirect_uri, :text, null: false
      add :code_challenge, :text
      add :code_challenge_method, :text
      add :expires_at, :utc_datetime_usec, null: false
      add :redeemed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:oauth_authorization_codes, [:code_hash])
    create index(:oauth_authorization_codes, [:client_id, :user_id])
  end
end
