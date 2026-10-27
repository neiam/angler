defmodule Angler.Conversations do
  @moduledoc """
  Direct-message thread aggregation.

  When a `:direct` status is created (locally or via federation), we fan out
  one `Conversation` row per recipient — including the author themselves —
  keyed on the sorted set of *other* participants. Repeat messages between
  the same set of people just bump the existing row's `last_status_id` and
  flip `unread` true.
  """

  import Ecto.Query, warn: false

  alias Angler.Conversations.Conversation
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses.{Mention, Status}

  @doc """
  Materialize/refresh conversation rows for a `:direct` status.

  No-op for non-direct statuses or when the status has no mentioned local
  recipients.
  """
  @spec record(Status.t()) :: :ok
  def record(%Status{visibility: :direct, id: status_id, profile_id: author_id}) do
    mentioned = mentioned_profile_ids(status_id)

    # Only owners that are *local* should get a conversation row. We resolve
    # locality at insert time.
    all_participants = [author_id | mentioned] |> Enum.uniq()

    Enum.each(all_participants, fn owner_id ->
      others = all_participants |> Enum.reject(&(&1 == owner_id)) |> Enum.sort()

      if local_profile?(owner_id) do
        upsert_for_owner(owner_id, others, status_id, owner_id != author_id)
      end
    end)

    :ok
  end

  def record(_), do: :ok

  defp upsert_for_owner(owner_id, others, status_id, unread?) do
    %{
      owner_id: owner_id,
      participant_ids: others,
      last_status_id: status_id,
      unread: unread?
    }
    |> Conversation.changeset()
    |> Repo.insert(
      on_conflict: [
        set: [last_status_id: status_id, unread: unread?, updated_at: DateTime.utc_now()]
      ],
      conflict_target: [:owner_id, :participant_ids]
    )
  end

  defp mentioned_profile_ids(status_id) do
    Repo.all(from m in Mention, where: m.status_id == ^status_id, select: m.profile_id)
  end

  defp local_profile?(profile_id) do
    Repo.exists?(
      from p in Profile,
        where: p.id == ^profile_id and is_nil(p.domain) and is_nil(p.status)
    )
  end

  ## Reads

  @spec list(integer(), keyword()) :: [Conversation.t()]
  def list(owner_id, opts \\ []) do
    cursor =
      Keyword.get_lazy(opts, :cursor, fn ->
        Angler.Pagination.MastodonCursor.parse(%{}, Keyword.get(opts, :limit, 20), 40)
      end)

    # Newest activity first, paged by the last status — what Mastodon does
    # and upstream now matches (9c81a75ad). Ordering by row id put a
    # months-old thread with a new reply below newer, quieter ones.
    from(c in Conversation, where: c.owner_id == ^owner_id and not is_nil(c.last_status_id))
    |> Angler.Pagination.MastodonCursor.apply(cursor, :last_status_id)
    |> Repo.all()
    |> Angler.Pagination.MastodonCursor.finalize_order(cursor, :last_status_id)
    |> Repo.preload([:last_status, last_status: :profile])
  end

  @spec get(integer(), integer()) :: Conversation.t() | nil
  def get(owner_id, id) do
    Repo.get_by(Conversation, owner_id: owner_id, id: id)
  end

  @spec mark_read(integer(), integer()) :: {:ok, Conversation.t()} | {:error, :not_found}
  def mark_read(owner_id, id) do
    case get(owner_id, id) do
      nil ->
        {:error, :not_found}

      conv ->
        conv
        |> Ecto.Changeset.change(unread: false, updated_at: DateTime.utc_now())
        |> Repo.update()
    end
  end

  @spec delete(integer(), integer()) :: :ok
  def delete(owner_id, id) do
    {_, _} =
      from(c in Conversation, where: c.owner_id == ^owner_id and c.id == ^id) |> Repo.delete_all()

    :ok
  end

  @doc """
  List the latest direct status per conversation thread for `owner_id`.
  Used by `GET /api/v1/timelines/direct`.
  """
  @spec direct_timeline(integer(), keyword()) :: [Status.t()]
  def direct_timeline(owner_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Repo.all(
      from c in Conversation,
        join: s in Status,
        on: s.id == c.last_status_id and is_nil(s.deleted_at),
        where: c.owner_id == ^owner_id,
        order_by: [desc: c.id],
        limit: ^limit,
        select: s
    )
  end
end
