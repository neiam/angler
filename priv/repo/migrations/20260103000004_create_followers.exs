defmodule Angler.Repo.Migrations.CreateFollowers do
  use Ecto.Migration

  def change do
    create table(:followers) do
      # `profile_id` is the followee. `following_id` is the follower. Names are
      # the upstream Pixelfed convention; "follower follows followee".
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :following_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :show_reblogs, :boolean, default: true, null: false
      add :notify, :boolean, default: false, null: false
      add :languages, {:array, :text}, default: [], null: false
      add :pending_remote, :boolean, default: false, null: false
      add :remote_url, :text
      add :accepted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:followers, [:profile_id, :following_id])
    create index(:followers, [:following_id])
    create index(:followers, [:pending_remote])
    create unique_index(:followers, [:remote_url], where: "remote_url IS NOT NULL")

    create table(:follow_requests) do
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :following_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :remote_url, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:follow_requests, [:profile_id, :following_id])
    create index(:follow_requests, [:following_id])
  end
end
