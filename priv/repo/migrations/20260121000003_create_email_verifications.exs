defmodule Angler.Repo.Migrations.CreateEmailVerifications do
  use Ecto.Migration

  def change do
    create table(:email_verifications) do
      add :user_id, references(:users, on_delete: :delete_all, type: :bigint), null: false
      add :email, :string, null: false
      add :user_token, :string, null: false
      add :random_token, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:email_verifications, [:user_id])
    create unique_index(:email_verifications, [:user_token])
    create unique_index(:email_verifications, [:random_token])
  end
end
