defmodule Angler.Repo.Migrations.CreateGroups do
  use Ecto.Migration

  def change do
    # Group categories — small lookup table; operator-seeded.
    create table(:group_categories, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :order, :integer, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:group_categories, [:slug])

    # Groups themselves.
    create table(:groups, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :owner_profile_id, references(:profiles, on_delete: :restrict), null: false
      add :category_id, references(:group_categories, on_delete: :nilify_all)

      add :privacy, :string, default: "public", null: false
      add :discoverable, :boolean, default: true, null: false
      add :post_policy, :string, default: "members", null: false
      add :comment_policy, :string, default: "members", null: false

      add :avatar_path, :string
      add :header_path, :string

      add :member_count, :integer, default: 1, null: false
      add :post_count, :integer, default: 0, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:groups, [:slug])
    create index(:groups, [:category_id])
    create index(:groups, [:discoverable])

    # Membership edges. accepted_at NULL = pending join request; non-null
    # = approved member. role tracks owner / admin / member.
    create table(:group_members, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :role, :string, default: "member", null: false
      add :accepted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:group_members, [:group_id, :profile_id])
    create index(:group_members, [:profile_id])
    create index(:group_members, [:group_id, :role])

    # Invitations — distinct from a join request; an admin pre-invites a
    # profile to skip the approval step.
    create table(:group_invites, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :inviter_profile_id, references(:profiles, on_delete: :nilify_all)
      add :accepted_at, :utc_datetime_usec
      add :declined_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:group_invites, [:group_id, :profile_id])

    # Per-group blocklist — e.g. a profile banned from posting in this group.
    create table(:group_blocks, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :reason, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:group_blocks, [:group_id, :profile_id])

    # Group reports — distinct from instance-level reports.
    create table(:group_reports, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :reporter_profile_id, references(:profiles, on_delete: :nilify_all)
      add :object_type, :string, null: false
      add :object_id, :bigint, null: false
      add :report_type, :string
      add :message, :text
      add :resolved_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:group_reports, [:group_id, :id])

    # Hook posts into groups via a nullable FK on `statuses`.
    alter table(:statuses) do
      add :group_id, references(:groups, on_delete: :nilify_all)
    end

    create index(:statuses, [:group_id, :id])
  end
end
