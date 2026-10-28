defmodule Angler.Conversations do
  @moduledoc """
  Direct-message conversations (Pixelfed v0.15's "DM v2").

  A conversation is a fixed set of participants — author plus everyone a
  `:direct` status mentions — so the same people always share one
  (`Conversation.hash/1`). Every `:direct` status, local or federated, is
  recorded into its conversation by `record/1`; the status *is* the
  message, so Mastodon clients, the legacy `/direct/thread` API and the
  v1.1 `/direct/conversations` API all see the same thing.

  Each member has a `Participant` row with their own state:

    * `"request"` — a local member who neither follows the sender nor
      accepts DMs from anyone (`public_dm`) starts here; it shows under the
      requests tab and becomes `"active"` when they accept or reply.
    * `"active"`, and `"left"` (groups only; hidden and unreachable).
    * `unread_count` / `last_read_message_id`, `muted_at`, `hidden_at`.

  A conversation stays out of every inbox until its first message
  (`last_activity_at`). See `AnglerWeb.MastodonAPI.DirectConversationController`.
  """

  import Ecto.Query, warn: false

  alias Angler.Accounts.{Settings, User}
  alias Angler.Conversations.{Conversation, Message, Participant}
  alias Angler.Follows
  alias Angler.Notifications
  alias Angler.Notifications.Notification
  alias Angler.Profiles.{BlocksMutes, Profile}
  alias Angler.Repo
  alias Angler.Statuses.{Mention, Status}

  @max_participants 10

  @doc "Most people a conversation can hold, the creator included."
  def max_participants, do: @max_participants

  @new_account_wait_s 72 * 3600

  @doc """
  May `user` start a conversation (upstream canInitiateConversation)? New
  accounts wait 72 hours, unless the instance allows new-account DMs
  (`INSTANCE_ALLOW_NEW_DMS`, on by default) or they're an admin.
  """
  @spec can_initiate?(User.t()) :: boolean()
  def can_initiate?(%User{is_admin: true}), do: true

  def can_initiate?(%User{inserted_at: at}) do
    Application.get_env(:angler, :allow_new_account_dms, true) == true or
      DateTime.diff(DateTime.utc_now(), at) >= @new_account_wait_s
  end

  ## Recording messages

  @doc """
  File a `:direct` status into its conversation (creating it on first
  message) and update every member's state. No-op for anything else.
  """
  @spec record(Status.t()) :: :ok
  def record(%Status{visibility: :direct, id: status_id, profile_id: author_id} = status) do
    members = [author_id | mentioned_profile_ids(status_id)] |> Enum.uniq()

    if length(members) >= 2 and length(members) <= @max_participants do
      conversation = find_or_create!(members, author_id)

      {_, _} =
        Repo.insert_all(Message, [%{conversation_id: conversation.id, status_id: status_id}],
          on_conflict: :nothing,
          conflict_target: [:status_id]
        )

      at = status.inserted_at || DateTime.utc_now()

      from(c in Conversation,
        where:
          c.id == ^conversation.id and
            (is_nil(c.last_message_id) or c.last_message_id < ^status_id)
      )
      |> Repo.update_all(set: [last_message_id: status_id, last_message_at: at, updated_at: at])

      fan_out(conversation.id, author_id, status_id, at)
    else
      # Too many people for a conversation: still a mention to each of them.
      for pid <- members, pid != author_id do
        Notifications.notify(%{
          recipient_id: pid,
          account_id: author_id,
          type: "mention",
          status_id: status_id
        })
      end
    end

    :ok
  end

  def record(_), do: :ok

  @doc """
  File a story reply or reaction (a `:direct` status mentioning only the
  story's author). Only followers can send one, so it never sits in
  requests (upstream DirectMessageService::storeStoryMessage).
  """
  @spec record_story_message(Status.t()) :: :ok
  def record_story_message(%Status{visibility: :direct, profile_id: sender_id} = status) do
    case mentioned_profile_ids(status.id) do
      [author_id] when author_id != sender_id ->
        conversation = find_or_create!([sender_id, author_id], sender_id)

        {_, _} =
          from(p in Participant,
            where: p.conversation_id == ^conversation.id and p.state == "request"
          )
          |> Repo.update_all(set: [state: "active"])

        record(status)

      _ ->
        record(status)
    end
  end

  @doc """
  Find the conversation for exactly `member_ids`, or create it with each
  member's starting state. `creator_id` is who is starting it.
  """
  @spec find_or_create!([integer()], integer()) :: Conversation.t()
  def find_or_create!(member_ids, creator_id) do
    hash = Conversation.hash(member_ids)

    case Repo.get_by(Conversation, participants_hash: hash) do
      %Conversation{} = c ->
        c

      nil ->
        now = DateTime.utc_now()

        {_, _} =
          Repo.insert_all(
            Conversation,
            [
              %{
                participants_hash: hash,
                type: if(length(Enum.uniq(member_ids)) > 2, do: "group", else: "dm"),
                created_by_profile_id: creator_id,
                inserted_at: now,
                updated_at: now
              }
            ],
            on_conflict: :nothing,
            conflict_target: [:participants_hash]
          )

        conversation = Repo.get_by!(Conversation, participants_hash: hash)

        rows =
          for pid <- Enum.uniq(member_ids) do
            %{
              conversation_id: conversation.id,
              profile_id: pid,
              state: initial_state(pid, creator_id),
              inserted_at: now,
              updated_at: now
            }
          end

        Repo.insert_all(Participant, rows,
          on_conflict: :nothing,
          conflict_target: [:conversation_id, :profile_id]
        )

        conversation
    end
  end

  # upstream DirectMessageService::initialState: the sender and remote
  # members start active; a local member only if they take DMs from anyone
  # or already follow the sender.
  defp initial_state(pid, pid), do: "active"

  defp initial_state(pid, sender_id) do
    case Repo.get(Profile, pid) do
      %Profile{domain: nil} = profile ->
        if open_dms?(profile) or follows?(pid, sender_id), do: "active", else: "request"

      _ ->
        "active"
    end
  end

  defp open_dms?(%Profile{is_private: true}), do: false

  defp open_dms?(%Profile{id: pid}) do
    case Repo.get_by(User, profile_id: pid) do
      %User{id: uid} -> Settings.account_settings(uid)["public_dm"] == true
      nil -> false
    end
  end

  # Does `follower_id` follow `followee_id` (accepted)?
  defp follows?(follower_id, followee_id),
    do: match?(%{accepted_at: %DateTime{}}, Follows.get_follower(followee_id, follower_id))

  # upstream fanOut: the sender has read up to their own message and, by
  # replying, accepts a request; every other local member who hasn't left or
  # blocked the sender gets an unread. Muted / hidden still count, but only
  # active, unmuted, visible conversations notify.
  defp fan_out(conversation_id, author_id, status_id, at) do
    from(p in Participant,
      where: p.conversation_id == ^conversation_id and p.profile_id == ^author_id
    )
    |> Repo.update_all(
      set: [
        last_read_message_id: status_id,
        last_activity_at: at,
        unread_count: 0,
        hidden_at: nil,
        updated_at: at
      ]
    )

    from(p in Participant,
      where:
        p.conversation_id == ^conversation_id and p.profile_id == ^author_id and
          p.state == "request"
    )
    |> Repo.update_all(set: [state: "active"])

    blockers = BlocksMutes.blocked_by_ids(author_id)

    from(p in Participant,
      join: pr in Profile,
      on: pr.id == p.profile_id,
      where:
        p.conversation_id == ^conversation_id and p.profile_id != ^author_id and
          p.state != "left" and is_nil(pr.domain) and p.profile_id not in ^blockers
    )
    |> Repo.update_all(inc: [unread_count: 1], set: [last_activity_at: at, updated_at: at])

    from(p in Participant,
      join: pr in Profile,
      on: pr.id == p.profile_id,
      where:
        p.conversation_id == ^conversation_id and p.profile_id != ^author_id and
          p.state == "active" and is_nil(p.muted_at) and is_nil(p.hidden_at) and
          is_nil(pr.domain) and p.profile_id not in ^blockers,
      select: p.profile_id
    )
    |> Repo.all()
    |> Enum.each(fn pid ->
      Notifications.notify(%{
        recipient_id: pid,
        account_id: author_id,
        type: "direct",
        status_id: status_id
      })
    end)

    :ok
  end

  defp mentioned_profile_ids(status_id) do
    Repo.all(from m in Mention, where: m.status_id == ^status_id, select: m.profile_id)
  end

  ## Reads — the v1.1 conversation API

  @doc """
  A page of `profile_id`'s conversations under `filter` (`"primary"`,
  `"requests"` or `"hidden"`), most recent activity first. `cursor` is the
  `{last_activity_at, participant_id}` of the previous page's last row.
  """
  @spec list(integer(), String.t(), pos_integer(), {DateTime.t(), integer()} | nil) ::
          [Participant.t()]
  def list(profile_id, filter, limit, cursor \\ nil) do
    from(p in Participant,
      where: p.profile_id == ^profile_id and not is_nil(p.last_activity_at),
      order_by: [desc: p.last_activity_at, desc: p.id],
      limit: ^limit
    )
    |> filter_inbox(filter)
    |> after_cursor(cursor)
    |> Repo.all()
    |> preload_for_render()
  end

  defp filter_inbox(q, "requests"),
    do: from(p in q, where: p.state == "request" and is_nil(p.hidden_at))

  defp filter_inbox(q, "hidden"),
    do: from(p in q, where: p.state in ["active", "request"] and not is_nil(p.hidden_at))

  defp filter_inbox(q, _primary),
    do: from(p in q, where: p.state == "active" and is_nil(p.hidden_at))

  defp after_cursor(q, nil), do: q

  defp after_cursor(q, {at, id}) do
    from(p in q, where: p.last_activity_at < ^at or (p.last_activity_at == ^at and p.id < ^id))
  end

  @doc "`%{primary: n, requests: n}` — conversations with something unread, per tab."
  @spec unread_count(integer()) :: %{primary: non_neg_integer(), requests: non_neg_integer()}
  def unread_count(profile_id) do
    base =
      from(p in Participant,
        where:
          p.profile_id == ^profile_id and is_nil(p.hidden_at) and not is_nil(p.last_activity_at)
      )

    primary =
      from(p in base, where: p.state == "active" and is_nil(p.muted_at) and p.unread_count > 0)
      |> Repo.aggregate(:count)

    requests = from(p in base, where: p.state == "request") |> Repo.aggregate(:count)

    %{primary: primary, requests: requests}
  end

  @doc "The viewer's participant row in conversation `id`, unless they've left it."
  @spec get(integer(), integer()) :: Participant.t() | nil
  def get(profile_id, conversation_id) do
    from(p in Participant,
      where:
        p.profile_id == ^profile_id and p.conversation_id == ^conversation_id and
          p.state != "left"
    )
    |> Repo.one()
    |> case do
      nil -> nil
      row -> hd(preload_for_render([row]))
    end
  end

  @doc """
  Messages of a conversation, newest first, without deleted ones or those by
  people the viewer blocks. `max_id` pages back; `min_id` fetches the page
  just above it. Returns `{messages, has_more?}`.
  """
  @spec messages(integer(), integer(), pos_integer(), keyword()) :: {[Status.t()], boolean()}
  def messages(conversation_id, viewer_id, limit, opts \\ []) do
    blocked = BlocksMutes.block_ids_for(viewer_id)

    q =
      from(s in Status,
        join: m in Message,
        on: m.status_id == s.id,
        where:
          m.conversation_id == ^conversation_id and is_nil(s.deleted_at) and
            s.profile_id not in ^blocked,
        limit: ^(limit + 1)
      )

    q =
      case {opts[:min_id], opts[:max_id]} do
        {min_id, _} when is_integer(min_id) ->
          from(s in q, where: s.id > ^min_id, order_by: [asc: s.id])

        {_, max_id} when is_integer(max_id) ->
          from(s in q, where: s.id < ^max_id, order_by: [desc: s.id])

        _ ->
          from(s in q, order_by: [desc: s.id])
      end

    rows = Repo.all(q)
    has_more? = length(rows) > limit

    rows =
      rows
      |> Enum.take(limit)
      |> Enum.sort_by(& &1.id, :desc)
      |> Repo.preload([:profile, mentions: :profile, media_attachments: []])

    {rows, has_more?}
  end

  @doc "Whether `status_id` is a live message of `conversation_id`."
  @spec message?(integer(), integer()) :: boolean()
  def message?(conversation_id, status_id) do
    Repo.exists?(
      from m in Message,
        join: s in Status,
        on: s.id == m.status_id and is_nil(s.deleted_at),
        where: m.conversation_id == ^conversation_id and m.status_id == ^status_id
    )
  end

  @doc "The conversation a status belongs to, if it's a DM."
  @spec conversation_id_for(integer()) :: integer() | nil
  def conversation_id_for(status_id) do
    Repo.one(from m in Message, where: m.status_id == ^status_id, select: m.conversation_id)
  end

  @doc "The 1:1 conversation between two profiles, if any."
  @spec between(integer(), integer()) :: Conversation.t() | nil
  def between(a, b), do: Repo.get_by(Conversation, participants_hash: Conversation.hash([a, b]))

  ## Reads — Mastodon /api/v1/conversations

  @doc """
  The viewer's conversations for Mastodon clients: not hidden, not left,
  with at least one message, newest message first, paged on the last
  message id (`MastodonCursor`). Rows are participant rows; their id is the
  Mastodon conversation id, as upstream.
  """
  @spec list_mastodon(integer(), map()) :: [Participant.t()]
  def list_mastodon(profile_id, cursor) do
    from(p in Participant,
      join: c in assoc(p, :conversation),
      where:
        p.profile_id == ^profile_id and p.state != "left" and is_nil(p.hidden_at) and
          not is_nil(c.last_message_id)
    )
    |> mastodon_cursor(cursor)
    |> Repo.all()
    |> preload_for_render()
  end

  defp mastodon_cursor(q, cursor) do
    q =
      cond do
        cursor.since_id -> from([p, c] in q, where: c.last_message_id > ^cursor.since_id)
        cursor.max_id -> from([p, c] in q, where: c.last_message_id < ^cursor.max_id)
        cursor.min_id -> from([p, c] in q, where: c.last_message_id > ^cursor.min_id)
        true -> q
      end

    dir = if is_integer(cursor.min_id), do: :asc, else: :desc
    from([p, c] in q, order_by: [{^dir, c.last_message_id}], limit: ^cursor.limit)
  end

  @doc "A Mastodon conversation id is the viewer's participant row id."
  @spec get_mastodon(integer(), integer()) :: Participant.t() | nil
  def get_mastodon(profile_id, participant_id) do
    from(p in Participant,
      where: p.id == ^participant_id and p.profile_id == ^profile_id and p.state != "left"
    )
    |> Repo.one()
    |> case do
      nil -> nil
      row -> hd(preload_for_render([row]))
    end
  end

  @doc "Latest message of each of the viewer's conversations (`/timelines/direct`)."
  @spec direct_timeline(integer(), keyword()) :: [Status.t()]
  def direct_timeline(profile_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Repo.all(
      from p in Participant,
        join: c in assoc(p, :conversation),
        join: s in Status,
        on: s.id == c.last_message_id and is_nil(s.deleted_at),
        where: p.profile_id == ^profile_id and p.state != "left" and is_nil(p.hidden_at),
        order_by: [desc: c.last_message_id],
        limit: ^limit,
        select: s
    )
  end

  defp preload_for_render(rows) do
    Repo.preload(rows,
      conversation: [
        last_message: [:profile, mentions: :profile, media_attachments: []],
        participants: from(p in Participant, order_by: p.id, preload: :profile)
      ]
    )
  end

  ## Writes

  @doc """
  Mark read up to `message_id` (or the newest message). The pointer never
  moves backwards; `unread_count` becomes the number of others' messages
  still above it.
  """
  @spec mark_read(Participant.t(), integer() | nil) :: Participant.t()
  def mark_read(%Participant{} = row, message_id \\ nil) do
    latest =
      from(m in Message,
        join: s in Status,
        on: s.id == m.status_id and is_nil(s.deleted_at),
        where: m.conversation_id == ^row.conversation_id,
        select: max(m.status_id)
      )
      |> then(fn q ->
        if message_id, do: from(m in q, where: m.status_id <= ^message_id), else: q
      end)
      |> Repo.one()

    if is_nil(latest) or (row.last_read_message_id && row.last_read_message_id >= latest) do
      row
    else
      remaining =
        Repo.aggregate(
          from(m in Message,
            join: s in Status,
            on: s.id == m.status_id and is_nil(s.deleted_at),
            where:
              m.conversation_id == ^row.conversation_id and m.status_id > ^latest and
                s.profile_id != ^row.profile_id
          ),
          :count
        )

      update!(row, last_read_message_id: latest, unread_count: remaining)
    end
  end

  @doc "Accept a message request."
  def accept(%Participant{state: "request"} = row), do: update!(row, state: "active")
  def accept(row), do: row

  def mute(%Participant{muted_at: nil} = row), do: update!(row, muted_at: DateTime.utc_now())
  def mute(row), do: row
  def unmute(row), do: update!(row, muted_at: nil)

  def hide(%Participant{hidden_at: nil} = row), do: update!(row, hidden_at: DateTime.utc_now())
  def hide(row), do: row
  def unhide(row), do: update!(row, hidden_at: nil)

  @doc "Leave a group conversation."
  @spec leave(Participant.t()) :: {:ok, Participant.t()} | {:error, :not_a_group}
  def leave(%Participant{conversation: %Conversation{type: "group"}} = row),
    do: {:ok, update!(row, state: "left", unread_count: 0)}

  def leave(_), do: {:error, :not_a_group}

  @doc "Rejoin / unhide on `POST conversations` for an existing conversation."
  @spec reopen(integer(), integer()) :: :ok
  def reopen(conversation_id, profile_id) do
    from(p in Participant,
      where: p.conversation_id == ^conversation_id and p.profile_id == ^profile_id
    )
    |> Repo.update_all(set: [hidden_at: nil, updated_at: DateTime.utc_now()])

    from(p in Participant,
      where:
        p.conversation_id == ^conversation_id and p.profile_id == ^profile_id and
          p.state == "left"
    )
    |> Repo.update_all(set: [state: "active"])

    :ok
  end

  @doc """
  After a message is deleted: repoint the conversation at its newest
  remaining message, take the message off unread counts that included it,
  and drop its notifications.
  """
  @spec message_deleted(integer(), integer()) :: :ok
  def message_deleted(conversation_id, status_id) do
    {newest, at} =
      Repo.one(
        from m in Message,
          join: s in Status,
          on: s.id == m.status_id and is_nil(s.deleted_at),
          where: m.conversation_id == ^conversation_id,
          order_by: [desc: m.status_id],
          limit: 1,
          select: {s.id, s.inserted_at}
      ) || {nil, nil}

    from(c in Conversation, where: c.id == ^conversation_id and c.last_message_id == ^status_id)
    |> Repo.update_all(set: [last_message_id: newest, last_message_at: at])

    from(p in Participant,
      where:
        p.conversation_id == ^conversation_id and p.unread_count > 0 and
          (is_nil(p.last_read_message_id) or p.last_read_message_id < ^status_id)
    )
    |> Repo.update_all(inc: [unread_count: -1])

    {_, _} =
      Repo.delete_all(
        from n in Notification, where: n.type == "direct" and n.status_id == ^status_id
      )

    :ok
  end

  defp update!(row, changes) do
    row |> Ecto.Changeset.change(changes) |> Repo.update!()
  end
end
