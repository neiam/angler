defmodule Angler.Repo.Migrations.CreateUserSettings do
  use Ecto.Migration

  def change do
    create table(:user_settings) do
      add :user_id, references(:users, on_delete: :delete_all, type: :bigint), null: false
      add :web, :map, null: false, default: %{}
      add :app, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_settings, [:user_id])
  end
end
