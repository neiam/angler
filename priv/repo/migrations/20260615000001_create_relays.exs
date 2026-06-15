defmodule Angler.Repo.Migrations.CreateRelays do
  use Ecto.Migration

  def change do
    # ActivityPub relay subscriptions (LitePub/Pleroma model). The operator
    # provides the relay's `actor_url` (e.g. https://relay.toot.io/actor); we
    # discover its `inbox_url` from the actor document and send a `Follow`
    # whose `object` is that actor, signed by the instance actor. `actor_url`
    # is also what we match inbound `Announce`s against.
    create table(:relays) do
      add :actor_url, :text, null: false
      add :inbox_url, :text, null: false
      add :follow_activity_id, :text, null: false
      add :state, :string, null: false, default: "pending"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:relays, [:actor_url])
    create unique_index(:relays, [:follow_activity_id])
    create index(:relays, [:inbox_url])
  end
end
