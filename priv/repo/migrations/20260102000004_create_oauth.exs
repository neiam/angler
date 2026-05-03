defmodule Angler.Repo.Migrations.CreateOauth do
  use Ecto.Migration

  def change do
    create table(:oauth_clients, primary_key: false) do
      # snowflake-style id assigned by the application
      add :id, :bigint, primary_key: true
      add :name, :text, null: false
      add :secret_hash, :bytea, null: false
      add :redirect_uris, {:array, :text}, null: false
      add :scopes, {:array, :text}, null: false, default: ["read"]
      add :website, :text
      add :owner_user_id, references(:users, on_delete: :nilify_all)
      add :revoked, :boolean, default: false, null: false
      # First-party clients (the official mobile/web apps) skip the consent
      # screen on authorization_code. Set explicitly via admin tooling.
      add :first_party, :boolean, default: false, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:oauth_clients, [:owner_user_id])
    create index(:oauth_clients, [:revoked])

    create table(:oauth_tokens, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :token_hash, :bytea, null: false
      add :refresh_hash, :bytea

      add :client_id, references(:oauth_clients, type: :bigint, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, on_delete: :delete_all)
      add :profile_id, references(:profiles, type: :bigint, on_delete: :delete_all)
      add :scopes, {:array, :text}, null: false
      add :expires_at, :utc_datetime_usec
      add :refresh_expires_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :ip, :text
      add :user_agent, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:oauth_tokens, [:token_hash])
    create unique_index(:oauth_tokens, [:refresh_hash], where: "refresh_hash IS NOT NULL")
    create index(:oauth_tokens, [:user_id])
    create index(:oauth_tokens, [:client_id])
    create index(:oauth_tokens, [:expires_at], where: "revoked_at IS NULL")
  end
end
