defmodule Angler.Repo.Migrations.AddAdminModerationToProfiles do
  use Ecto.Migration

  def change do
    alter table(:profiles) do
      # Pixelfed-shape per-profile moderation flags.
      add :unlisted, :boolean, default: false, null: false
      add :cw, :boolean, default: false, null: false
      add :no_autolink, :boolean, default: false, null: false
    end
  end
end
