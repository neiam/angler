defmodule Angler.Repo.Migrations.AddInsertedAtIndexToStatusHashtags do
  use Ecto.Migration

  # `/tags` ranks tags over a recent window, keyed on when the tag was used.
  def change do
    create index(:status_hashtags, [:inserted_at])
  end
end
