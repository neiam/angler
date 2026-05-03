defmodule Angler.Repo.Migrations.CreateAppRegisters do
  use Ecto.Migration

  def change do
    create table(:app_registers) do
      add :email, :citext, null: false
      add :verify_code_hash, :bytea, null: false
      add :verify_code_attempts, :integer, default: 0, null: false
      add :uses, :integer, default: 1, null: false
      add :email_delivered_at, :utc_datetime_usec
      add :ip, :text
      timestamps(type: :utc_datetime_usec)
    end

    # Pixelfed dedupes by email — one in-flight registration per address.
    create unique_index(:app_registers, [:email])
  end
end
