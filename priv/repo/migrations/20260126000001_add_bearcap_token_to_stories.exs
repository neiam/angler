defmodule Angler.Repo.Migrations.AddBearcapTokenToStories do
  use Ecto.Migration

  def change do
    alter table(:stories) do
      add :bearcap_token, :string
    end

    create index(:stories, [:bearcap_token], where: "bearcap_token IS NOT NULL")
  end
end
