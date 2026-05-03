defmodule Angler.Repo.Migrations.CreateTimelineMarkers do
  use Ecto.Migration

  def change do
    create table(:timeline_markers) do
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :timeline, :string, null: false
      add :last_read_id, :bigint, null: false
      add :version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:timeline_markers, [:profile_id, :timeline])
  end
end
