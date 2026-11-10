defmodule Angler.Repo.Migrations.AddTrigramIndexToStatusesCaption do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Post search (`Angler.Search.statuses/3`) is `caption ILIKE '%q%'`; without
  # this a query matching few posts scans the whole table. Needs >= 3 chars of
  # query to be usable (trigrams).
  def change do
    create index(:statuses, ["caption gin_trgm_ops"],
             name: :statuses_caption_trgm_index,
             using: :gin,
             where: "deleted_at IS NULL",
             concurrently: true
           )
  end
end
