defmodule Angler.Repo.Migrations.CreatePlaces do
  use Ecto.Migration

  def change do
    create table(:places) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :country, :string
      add :lat, :float
      add :long, :float
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:places, [:slug])
    create index(:places, [:country])

    alter table(:statuses) do
      add :place_id, references(:places, on_delete: :nilify_all)
    end

    create index(:statuses, [:place_id])
  end
end
