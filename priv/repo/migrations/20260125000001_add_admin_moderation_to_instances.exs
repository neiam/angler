defmodule Angler.Repo.Migrations.AddAdminModerationToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      # Pixelfed-shape moderation flags. `banned` already exists; these
      # add the softer states the admin UI exposes.
      add :unlisted, :boolean, default: false, null: false
      add :auto_cw, :boolean, default: false, null: false
    end

    create index(:instances, [:unlisted])
    create index(:instances, [:auto_cw])
  end
end
