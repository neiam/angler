defmodule Angler.Repo.Migrations.AddDeliveryBackoffToInstances do
  use Ecto.Migration

  # Per-host delivery health, as upstream's instances.delivery_failures /
  # delivery_timeout / delivery_next_after (see Angler.Federation.DeliveryHosts).
  def change do
    alter table(:instances) do
      add :delivery_failures, :integer, default: 0, null: false
      add :delivery_timeout, :boolean, default: false, null: false
      add :delivery_next_after, :utc_datetime_usec
    end

    create index(:instances, [:domain],
             where: "delivery_failures > 0",
             name: :instances_delivery_failing_index
           )
  end
end
