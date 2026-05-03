defmodule Angler.Repo.Migrations.CreateInstanceActors do
  use Ecto.Migration

  def change do
    create table(:instance_actors) do
      add :public_key_pem, :text, null: false
      add :private_key_pem, :bytea, null: false
      add :key_id, :text, null: false
      add :owner_url, :text, null: false
      add :inbox_url, :text, null: false
      add :outbox_url, :text, null: false
      add :preferred_username, :citext, null: false
      add :name, :text
      add :summary, :text
      add :rotated_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:instance_actors, [:key_id])
  end
end
