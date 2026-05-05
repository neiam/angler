defmodule Angler.Repo.Migrations.AddExpoPushToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :expo_token, :string
      add :notify_enabled, :boolean, default: false, null: false
      add :notify_like, :boolean, default: false, null: false
      add :notify_follow, :boolean, default: false, null: false
      add :notify_mention, :boolean, default: false, null: false
      add :notify_comment, :boolean, default: false, null: false
    end

    create index(:users, [:expo_token], where: "expo_token IS NOT NULL")
  end
end
