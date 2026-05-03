defmodule Angler.Repo.Migrations.CreateNodeStats do
  use Ecto.Migration

  def change do
    create table(:node_stats, primary_key: false) do
      # singleton row, id 1
      add :id, :integer, primary_key: true, default: 1
      add :user_count, :integer, default: 0, null: false
      add :status_count, :integer, default: 0, null: false
      add :domain_count, :integer, default: 0, null: false
      add :active_month, :integer, default: 0, null: false
      add :active_halfyear, :integer, default: 0, null: false
      add :local_posts, :integer, default: 0, null: false
      add :local_comments, :integer, default: 0, null: false
      add :computed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end
  end
end
