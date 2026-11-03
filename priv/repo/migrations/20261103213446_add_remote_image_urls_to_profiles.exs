defmodule Angler.Repo.Migrations.AddRemoteImageUrlsToProfiles do
  use Ecto.Migration

  # Where a remote profile's avatar and header came from, so a refresh only
  # downloads them again when the actor points somewhere new.
  def change do
    alter table(:profiles) do
      add :avatar_remote_url, :text
      add :header_remote_url, :text
    end
  end
end
