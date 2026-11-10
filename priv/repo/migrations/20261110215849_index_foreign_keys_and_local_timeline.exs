defmodule Angler.Repo.Migrations.IndexForeignKeysAndLocalTimeline do
  use Ecto.Migration

  # Built concurrently so large tables (statuses, notifications) stay
  # writable while the indexes build.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Foreign keys whose ON DELETE action (cascade / set null) otherwise
  # seq-scans the referencing table. `statuses.profile_id` and
  # `statuses.reblog_of_id` already have indexes, but those are partial
  # (`deleted_at IS NULL`) and the FK triggers can't use them.
  @fk_indexes [
    {:statuses, [:profile_id]},
    {:statuses, [:reblog_of_id]},
    {:statuses, [:in_reply_to_profile_id]},
    {:notifications, [:status_id]},
    {:notifications, [:account_id]},
    {:bookmarks, [:status_id]},
    {:pinned_statuses, [:status_id]},
    {:collection_items, [:status_id]},
    {:dm_conversations, [:last_message_id]},
    {:dm_conversations, [:created_by_profile_id]},
    {:oauth_tokens, [:profile_id]},
    {:oauth_authorization_codes, [:user_id]},
    {:profile_mutes, [:target_id]},
    {:poll_votes, [:profile_id]},
    {:reports, [:profile_id]},
    {:reports, [:action_taken_by_account_id]},
    {:announcement_dismissals, [:profile_id]},
    {:featured_tags, [:hashtag_id]},
    {:account_actions, [:moderator_account_id]},
    {:account_actions, [:report_id]},
    {:admin_invites, [:created_by_user_id]},
    {:groups, [:owner_profile_id]},
    {:group_invites, [:profile_id]},
    {:group_invites, [:inviter_profile_id]},
    {:group_blocks, [:profile_id]},
    {:group_reports, [:reporter_profile_id]},
    {:profiles, [:moved_to_id]},
    {:curated_registers, [:approved_by_admin_id]},
    {:curated_register_activities, [:admin_id]}
  ]

  @local_timeline_where "local AND visibility = 'public' AND deleted_at IS NULL " <>
                          "AND in_reply_to_id IS NULL AND in_reply_to_uri IS NULL"

  def up do
    for {table, cols} <- @fk_indexes do
      create_if_not_exists index(table, cols, concurrently: true)
    end

    # Local public timeline (`Timelines.public/2` with `local_only`):
    # otherwise walks `(visibility, id DESC)` discarding remote rows.
    create_if_not_exists index(:statuses, ["id DESC"],
                           name: :statuses_local_public_timeline_index,
                           where: @local_timeline_where,
                           concurrently: true
                         )

    # Covered by the unique (poll_id, position) index.
    drop_if_exists index(:poll_options, [:poll_id], concurrently: true)
  end

  def down do
    create_if_not_exists index(:poll_options, [:poll_id], concurrently: true)

    drop_if_exists index(:statuses, ["id DESC"],
                     name: :statuses_local_public_timeline_index,
                     concurrently: true
                   )

    for {table, cols} <- @fk_indexes do
      drop_if_exists index(table, cols, concurrently: true)
    end
  end
end
