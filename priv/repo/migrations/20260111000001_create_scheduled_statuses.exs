defmodule Angler.Repo.Migrations.CreateScheduledStatuses do
  use Ecto.Migration

  def change do
    create table(:scheduled_statuses, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :params, :jsonb, null: false
      add :media_ids, {:array, :bigint}, null: false, default: []
      add :scheduled_at, :utc_datetime_usec, null: false
      add :fired_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:scheduled_statuses, [:profile_id, "id DESC"])

    create index(:scheduled_statuses, [:scheduled_at],
             where: "fired_at IS NULL",
             name: "scheduled_statuses_due_idx"
           )
  end
end
