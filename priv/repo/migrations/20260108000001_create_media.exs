defmodule Angler.Repo.Migrations.CreateMedia do
  use Ecto.Migration

  def change do
    create table(:media, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :status_id, references(:statuses, on_delete: :nilify_all, type: :bigint)

      add :media_type, :text, null: false
      add :sha256, :bytea
      add :size_bytes, :integer
      add :width, :integer
      add :height, :integer
      add :duration_ms, :integer
      add :blurhash, :text

      add :caption, :text
      add :license, :text

      add :remote_url, :text
      add :path_original, :text
      add :path_thumb, :text
      add :path_preview, :text
      add :storage, :text, default: "local", null: false
      add :status, :text, default: "pending", null: false

      add :metadata, :map, default: %{}

      add :unattached_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:media, [:status_id])
    create index(:media, [:profile_id, "id DESC"])
    create unique_index(:media, [:sha256, :profile_id], where: "sha256 IS NOT NULL")
  end
end
