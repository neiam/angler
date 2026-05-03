defmodule Angler.Repo.Migrations.CreatePolls do
  use Ecto.Migration

  def change do
    create table(:polls, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :status_id, references(:statuses, on_delete: :delete_all, type: :bigint), null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :multiple, :boolean, null: false, default: false
      add :hide_totals, :boolean, null: false, default: false
      add :voters_count, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:polls, [:status_id])

    create table(:poll_options, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :poll_id, references(:polls, on_delete: :delete_all, type: :bigint), null: false
      add :position, :integer, null: false
      add :title, :text, null: false
      add :votes_count, :integer, null: false, default: 0
    end

    create unique_index(:poll_options, [:poll_id, :position])
    create index(:poll_options, [:poll_id])

    create table(:poll_votes, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :poll_id, references(:polls, on_delete: :delete_all, type: :bigint), null: false

      add :option_id, references(:poll_options, on_delete: :delete_all, type: :bigint),
        null: false

      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:poll_votes, [:poll_id, :profile_id, :option_id])
    create index(:poll_votes, [:option_id])
  end
end
