defmodule Angler.Repo.Migrations.SitePagesAndFeatureToggles do
  @moduledoc """
  * `site_pages` — admin-written Markdown for the terms, privacy, help and
    other `/site/*` pages (upstream `pages`).
  * `instance_settings.toggles` — the admin config switches
    (`/api/admin/config`), persisted instead of living in one node's memory.
  """

  use Ecto.Migration

  def change do
    create table(:site_pages) do
      add :slug, :string, null: false
      add :title, :string
      add :content, :text, null: false, default: ""

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:site_pages, [:slug])

    alter table(:instance_settings) do
      add :toggles, :map
    end
  end
end
