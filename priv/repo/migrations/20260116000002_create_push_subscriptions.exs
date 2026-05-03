defmodule Angler.Repo.Migrations.CreatePushSubscriptions do
  use Ecto.Migration

  def change do
    create table(:push_subscriptions) do
      add :token_id, references(:oauth_tokens, on_delete: :delete_all, type: :bigint), null: false
      add :endpoint, :text, null: false
      add :p256dh, :text, null: false
      add :auth, :text, null: false
      add :alerts, :map, null: false, default: %{}
      add :policy, :string, null: false, default: "all"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:push_subscriptions, [:token_id])
  end
end
