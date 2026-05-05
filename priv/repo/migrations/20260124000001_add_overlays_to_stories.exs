defmodule Angler.Repo.Migrations.AddOverlaysToStories do
  use Ecto.Migration

  def change do
    alter table(:stories) do
      add :overlays, :jsonb, null: false, default: "[]"
    end
  end
end
