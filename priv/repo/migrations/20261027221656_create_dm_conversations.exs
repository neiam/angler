defmodule Angler.Repo.Migrations.CreateDmConversations do
  @moduledoc """
  DM v2 (Pixelfed v0.15): a conversation is a fixed set of participants
  (identified by a hash of their sorted profile ids), with per-participant
  state — read pointer, unread count, request/active/left, muted, hidden.

  Messages stay `:direct` statuses; `dm_conversation_messages` records which
  conversation each belongs to. Replaces the per-owner `conversations`
  table, which is backfilled here and dropped.
  """

  use Ecto.Migration

  @hash "encode(sha256(convert_to(array_to_string(members, ':'), 'UTF8')), 'hex')"

  def up do
    create table(:dm_conversations) do
      add :type, :string, size: 16, null: false, default: "dm"
      add :participants_hash, :string, size: 64, null: false
      add :name, :string, size: 100
      add :created_by_profile_id, references(:profiles, on_delete: :nilify_all, type: :bigint)
      add :last_message_id, references(:statuses, on_delete: :nilify_all, type: :bigint)
      add :last_message_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:dm_conversations, [:participants_hash])

    create table(:dm_conversation_participants) do
      add :conversation_id, references(:dm_conversations, on_delete: :delete_all), null: false
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :state, :string, size: 16, null: false, default: "active"
      add :last_read_message_id, :bigint
      add :unread_count, :integer, null: false, default: 0
      add :last_activity_at, :utc_datetime_usec
      add :muted_at, :utc_datetime_usec
      add :hidden_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:dm_conversation_participants, [:conversation_id, :profile_id])
    create index(:dm_conversation_participants, [:profile_id, :state, :last_activity_at])

    create table(:dm_conversation_messages) do
      add :conversation_id, references(:dm_conversations, on_delete: :delete_all), null: false
      add :status_id, references(:statuses, on_delete: :delete_all, type: :bigint), null: false
    end

    create unique_index(:dm_conversation_messages, [:status_id])
    create index(:dm_conversation_messages, [:conversation_id, :status_id])

    flush()
    backfill()

    drop table(:conversations)
  end

  def down do
    drop table(:dm_conversation_messages)
    drop table(:dm_conversation_participants)
    drop table(:dm_conversations)

    create table(:conversations, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :owner_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :participant_ids, {:array, :bigint}, null: false, default: []
      add :last_status_id, references(:statuses, on_delete: :nilify_all, type: :bigint)
      add :unread, :boolean, null: false, default: true
      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversations, [:owner_id, "id DESC"])
    create unique_index(:conversations, [:owner_id, :participant_ids])
  end

  # Every live direct status, grouped by its author + mentioned profiles,
  # becomes a conversation. Read state comes from the old per-owner rows.
  defp backfill do
    execute("""
    CREATE TEMP TABLE dm_backfill ON COMMIT DROP AS
    SELECT s.id AS status_id, s.profile_id AS author_id, s.inserted_at AS at,
           ARRAY(
             SELECT DISTINCT u FROM unnest(
               array_append(
                 COALESCE((SELECT array_agg(m.profile_id) FROM mentions m WHERE m.status_id = s.id),
                          '{}'::bigint[]),
                 s.profile_id)) u
             ORDER BY u
           ) AS members
    FROM statuses s
    WHERE s.visibility = 'direct' AND s.deleted_at IS NULL
    """)

    execute("DELETE FROM dm_backfill WHERE cardinality(members) < 2")

    execute("""
    INSERT INTO dm_conversations
      (participants_hash, type, created_by_profile_id, last_message_id, last_message_at,
       inserted_at, updated_at)
    SELECT #{@hash},
           CASE WHEN cardinality(members) > 2 THEN 'group' ELSE 'dm' END,
           (array_agg(author_id ORDER BY status_id))[1],
           max(status_id), max(at), min(at), max(at)
    FROM dm_backfill
    GROUP BY members
    """)

    execute("""
    INSERT INTO dm_conversation_messages (conversation_id, status_id)
    SELECT c.id, b.status_id
    FROM dm_backfill b
    JOIN dm_conversations c ON c.participants_hash = #{String.replace(@hash, "members", "b.members")}
    """)

    execute("""
    INSERT INTO dm_conversation_participants
      (conversation_id, profile_id, state, last_read_message_id, unread_count,
       last_activity_at, inserted_at, updated_at)
    SELECT c.id, u.pid, 'active',
           CASE WHEN COALESCE(old.unread, false) THEN NULL ELSE c.last_message_id END,
           CASE WHEN COALESCE(old.unread, false) THEN 1 ELSE 0 END,
           c.last_message_at, now(), now()
    FROM (SELECT DISTINCT members FROM dm_backfill) g
    JOIN dm_conversations c ON c.participants_hash = #{String.replace(@hash, "members", "g.members")}
    CROSS JOIN LATERAL unnest(g.members) AS u(pid)
    LEFT JOIN conversations old
      ON old.owner_id = u.pid
     AND old.participant_ids = ARRAY(SELECT x FROM unnest(g.members) x WHERE x <> u.pid ORDER BY x)
    """)
  end
end
