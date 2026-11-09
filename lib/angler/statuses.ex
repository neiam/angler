defmodule Angler.Statuses do
  @moduledoc """
  Status read + write API.

  Local status creation goes through `create_local/2`. Inbound federation
  uses `create_remote/1` (no rendering, attrs come pre-built from AS2).
  """

  import Ecto.Query, warn: false

  alias Angler.Content.Lexer
  alias Angler.Hashtags
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses.{Mention, Status, StatusHashtag}

  ## Reads

  @doc "Get a non-deleted status by snowflake id (preloads profile)."
  @spec get(integer()) :: Status.t() | nil
  def get(id) when is_integer(id) do
    Status
    |> where([s], s.id == ^id and is_nil(s.deleted_at))
    |> preload(:profile)
    |> Repo.one()
  end

  @doc """
  Public (non-deleted, top-level) statuses authored by `profile_id`, newest
  first. Backs the anonymous web profile page; excludes replies so the grid
  reads like a profile feed.
  """
  @spec list_public_for_profile(integer(), pos_integer()) :: [Status.t()]
  def list_public_for_profile(profile_id, limit \\ 40) when is_integer(profile_id) do
    Status
    |> where([s], s.profile_id == ^profile_id)
    |> where([s], s.visibility == :public and is_nil(s.deleted_at))
    |> where([s], is_nil(s.in_reply_to_id) and is_nil(s.in_reply_to_uri))
    |> order_by([s], desc: s.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @profile_page_preloads [
    :profile,
    {:mentions, :profile},
    {:status_hashtags, :hashtag},
    :media_attachments
  ]

  @doc """
  Every non-deleted status authored by `profile_id` (all visibilities, including
  replies), oldest first, with render associations preloaded. Backs the account
  data export — the caller serializes each to an ActivityPub object.
  """
  @spec list_for_export(integer()) :: [Status.t()]
  def list_for_export(profile_id) when is_integer(profile_id) do
    Status
    |> where([s], s.profile_id == ^profile_id and is_nil(s.deleted_at))
    |> order_by([s], asc: s.id)
    |> preload(^@profile_page_preloads)
    |> Repo.all()
  end

  @doc """
  A page of top-level statuses for a profile page, newest first, with render
  associations preloaded. Cursor-paginated via `:max_id` (returns rows with
  `id < max_id`).

  Visibility is owner-scoped: only the profile owner (`opts[:viewer_id] ==
  profile_id`) may request anything beyond public posts. `opts[:filter]`:

    * `:public` — public only (the default, and forced for non-owners)
    * `:unlisted` — unlisted only (owner)
    * `:all` — public + unlisted + private, i.e. everything on the owner's
      profile except DMs (owner)
  """
  @spec list_for_profile_page(integer(), keyword()) :: [Status.t()]
  def list_for_profile_page(profile_id, opts \\ []) when is_integer(profile_id) do
    owner? = opts[:viewer_id] == profile_id
    filter = if owner?, do: opts[:filter] || :all, else: :public
    limit = opts[:limit] || 30

    Status
    |> where([s], s.profile_id == ^profile_id)
    |> where([s], s.visibility in ^profile_page_visibilities(filter))
    |> where([s], is_nil(s.deleted_at) and is_nil(s.in_reply_to_id))
    |> where([s], is_nil(s.in_reply_to_uri))
    |> profile_page_before(opts[:max_id])
    |> order_by([s], desc: s.id)
    |> limit(^limit)
    |> preload(^@profile_page_preloads)
    |> Repo.all()
  end

  defp profile_page_visibilities(:unlisted), do: [:unlisted]
  defp profile_page_visibilities(:all), do: [:public, :unlisted, :private]
  defp profile_page_visibilities(_), do: [:public]

  defp profile_page_before(query, nil), do: query
  defp profile_page_before(query, max_id), do: where(query, [s], s.id < ^max_id)

  @doc "Get a non-deleted status by AS2 `id` / `uri`."
  @spec get_by_uri(String.t()) :: Status.t() | nil
  def get_by_uri(uri) when is_binary(uri) do
    Status
    |> where([s], s.uri == ^uri and is_nil(s.deleted_at))
    |> preload(:profile)
    |> Repo.one()
  end

  @doc """
  A status by its ActivityPub id: a remote one's `uri`, or a local one's
  canonical `<base>/p/<username>/<id>` URL (local statuses have no `uri`).
  """
  @spec get_by_ap_id(String.t()) :: Status.t() | nil
  def get_by_ap_id(id) when is_binary(id) do
    get_by_uri(id) || get_by_local_url(id)
  end

  defp get_by_local_url(url) do
    with [_, rest] <- String.split(url, AnglerWeb.Endpoint.url() <> "/p/", parts: 2),
         [_username, id_str] <- String.split(rest, "/"),
         {id, ""} <- Integer.parse(id_str) do
      get(id)
    else
      _ -> nil
    end
  end

  @doc """
  Whether `status` is visible to `viewer_id` (or anonymous if nil).

  Visibility rules:
    * public, unlisted — visible to everyone
    * private — visible only to followers (and the author)
    * direct — visible only to mentioned recipients (and the author)
  """
  @spec visible_to?(Status.t(), integer() | nil) :: boolean()
  def visible_to?(%Status{visibility: v}, _) when v in [:public, :unlisted], do: true

  def visible_to?(%Status{visibility: _, profile_id: author}, viewer)
      when not is_nil(viewer) and author == viewer,
      do: true

  def visible_to?(%Status{visibility: :private, profile_id: author}, viewer)
      when not is_nil(viewer) do
    Repo.exists?(
      from f in Angler.Follows.Follower,
        where: f.profile_id == ^author and f.following_id == ^viewer and not is_nil(f.accepted_at)
    )
  end

  def visible_to?(%Status{visibility: :direct, id: status_id}, viewer) when not is_nil(viewer) do
    Repo.exists?(
      from m in Angler.Statuses.Mention,
        where: m.status_id == ^status_id and m.profile_id == ^viewer
    )
  end

  def visible_to?(_, _), do: false

  ## Thread context

  @ancestors_cap 40
  @descendants_cap 60

  @doc """
  Walk the in_reply_to chain upward from `status`, oldest-first. Capped at
  #{@ancestors_cap} statuses. Filters out anything `viewer_id` can't see.
  """
  @spec ancestors(Status.t(), integer() | nil) :: [Status.t()]
  def ancestors(%Status{in_reply_to_id: nil}, _viewer), do: []

  def ancestors(%Status{} = status, viewer_id) do
    walk_ancestors(status.in_reply_to_id, viewer_id, [], @ancestors_cap)
  end

  defp walk_ancestors(nil, _viewer, acc, _cap), do: acc
  defp walk_ancestors(_id, _viewer, acc, 0), do: acc

  defp walk_ancestors(id, viewer_id, acc, remaining) do
    case Repo.get(Status, id) |> preload_for_render() do
      nil ->
        acc

      %Status{deleted_at: %DateTime{}} ->
        acc

      %Status{} = parent ->
        if visible_to?(parent, viewer_id) do
          walk_ancestors(parent.in_reply_to_id, viewer_id, [parent | acc], remaining - 1)
        else
          acc
        end
    end
  end

  @doc """
  Breadth-first walk of the reply tree under `status`, ordered by status id
  ascending. Capped at #{@descendants_cap} statuses.
  """
  @spec descendants(Status.t(), integer() | nil) :: [Status.t()]
  def descendants(%Status{} = status, viewer_id) do
    bfs([status.id], viewer_id, [], @descendants_cap)
  end

  defp bfs([], _viewer, acc, _cap), do: Enum.reverse(acc)
  defp bfs(_, _viewer, acc, 0), do: Enum.reverse(acc)

  defp bfs([id | rest], viewer_id, acc, remaining) do
    children =
      from(s in Status,
        where: s.in_reply_to_id == ^id and is_nil(s.deleted_at),
        order_by: [asc: s.id]
      )
      |> Repo.all()
      |> preload_for_render()
      |> Enum.filter(&visible_to?(&1, viewer_id))

    take = Enum.take(children, remaining)
    new_acc = Enum.reduce(take, acc, fn s, a -> [s | a] end)
    bfs(rest ++ Enum.map(take, & &1.id), viewer_id, new_acc, remaining - length(take))
  end

  defp preload_for_render(nil), do: nil

  defp preload_for_render(%Status{} = s) do
    Repo.preload(s,
      profile: [],
      mentions: :profile,
      status_hashtags: :hashtag,
      media_attachments: []
    )
  end

  defp preload_for_render(list) when is_list(list) do
    Repo.preload(list,
      profile: [],
      mentions: :profile,
      status_hashtags: :hashtag,
      media_attachments: []
    )
  end

  ## Local edit

  @doc """
  Update a local status: caption, spoiler, sensitive, language. Snapshots
  the prior version into `status_edits` so `GET /:id/history` can render
  it back later. Bumps `edited_at`. Caller (controller) is responsible for
  enqueueing the outbound `Update Note` delivery.

  Returns `{:ok, status}` (preloaded) or `{:error, reason}`.
  """
  @spec update_local(integer(), Angler.Profiles.Profile.t(), map()) ::
          {:ok, Status.t()} | {:error, atom() | Ecto.Changeset.t()}
  def update_local(status_id, %Angler.Profiles.Profile{id: profile_id}, attrs)
      when is_integer(status_id) and is_map(attrs) do
    attrs = stringify(attrs)

    case Repo.get(Status, status_id) do
      nil ->
        {:error, :not_found}

      %Status{deleted_at: %DateTime{}} ->
        {:error, :not_found}

      %Status{profile_id: pid} when pid != profile_id ->
        {:error, :forbidden}

      %Status{local: false} ->
        {:error, :forbidden}

      %Status{} = status ->
        do_update(status, attrs)
    end
  end

  defp do_update(%Status{} = status, attrs) do
    caption =
      case attrs["status"] do
        s when is_binary(s) -> s
        _ -> status.caption
      end

    sensitive? =
      if Map.has_key?(attrs, "sensitive"), do: truthy?(attrs["sensitive"]), else: status.is_nsfw

    spoiler = Map.get(attrs, "spoiler_text", status.cw_summary)
    lang = Map.get(attrs, "language", status.language)

    quote_policy =
      if Map.has_key?(attrs, "quote_approval_policy") do
        parse_quote_policy(attrs)
      else
        {:ok, status.quote_policy}
      end

    with {:ok, quote_policy} <- quote_policy do
      do_update(status, caption, sensitive?, spoiler, lang, quote_policy)
    end
  end

  defp do_update(status, caption, sensitive?, spoiler, lang, quote_policy) do
    lex = Angler.Content.Lexer.render(caption)

    Repo.transaction(fn ->
      snapshot_edit!(status)

      {:ok, updated} =
        status
        |> Status.changeset(%{
          caption: caption,
          rendered: lex.html,
          is_nsfw: sensitive?,
          cw_summary: spoiler,
          language: lang,
          quote_policy: quote_policy,
          edited_at: DateTime.utc_now()
        })
        |> Repo.update()

      loaded = preload_local(updated)
      Angler.Streaming.broadcast_status_edit(loaded)
      loaded
    end)
  end

  @doc """
  Set (or with `nil`, clear back to the account default) a post's
  `quote_approval_policy` (`PUT /statuses/:id/interaction_policy`).
  Owner-only, original non-direct posts. Not federated: the policy is
  enforced on each QuoteRequest, and peers see it on their next fetch.
  """
  @spec set_quote_policy(integer(), Profile.t(), term()) ::
          {:ok, Status.t()} | {:error, :not_found | :bad_quote_policy}
  def set_quote_policy(status_id, %Profile{id: profile_id}, value) when is_integer(status_id) do
    with %Status{profile_id: ^profile_id, reblog_of_id: nil, local: true} = status
         when status.visibility != :direct <- get(status_id),
         {:ok, flags} <- parse_quote_policy(%{"quote_approval_policy" => value}) do
      status |> Ecto.Changeset.change(quote_policy: flags) |> Repo.update()
    else
      {:error, _} = err -> err
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Change a local status's visibility. Owner-only (`profile` must be the author),
  local statuses only. Used by the profile page to lift posts out of `unlisted`
  (e.g. a silent import) into `public`.

  Visibility-only change: it does not snapshot edit history or bump `edited_at`,
  and does not re-run follower fan-out.
  """
  @spec set_visibility(integer(), Angler.Profiles.Profile.t(), atom()) ::
          {:ok, Status.t()} | {:error, :not_found | :forbidden}
  def set_visibility(status_id, %Angler.Profiles.Profile{id: profile_id}, visibility)
      when is_integer(status_id) and visibility in [:public, :unlisted, :private] do
    case Repo.get(Status, status_id) do
      nil ->
        {:error, :not_found}

      %Status{deleted_at: %DateTime{}} ->
        {:error, :not_found}

      %Status{profile_id: pid} when pid != profile_id ->
        {:error, :forbidden}

      %Status{local: false} ->
        {:error, :forbidden}

      %Status{} = status ->
        status
        |> Status.changeset(%{visibility: visibility, scope: Atom.to_string(visibility)})
        |> Repo.update()
    end
  end

  defp snapshot_edit!(%Status{} = status) do
    %{
      status_id: status.id,
      caption: status.caption,
      rendered: status.rendered,
      spoiler_text: status.cw_summary,
      is_nsfw: status.is_nsfw,
      media_attachments: %{},
      poll: nil
    }
    |> Angler.Statuses.StatusEdit.changeset()
    |> Repo.insert!()
  end

  @doc "All historical edits for a status, oldest-first."
  @spec edit_history(integer()) :: [Angler.Statuses.StatusEdit.t()]
  def edit_history(status_id) when is_integer(status_id) do
    Repo.all(
      from e in Angler.Statuses.StatusEdit,
        where: e.status_id == ^status_id,
        order_by: [asc: e.id]
    )
  end

  ## Archive

  @doc """
  Archive a top-level local status. Stores the prior visibility on the
  status row's `scope` so `unarchive_local/2` can restore it. Top-level
  only — replies and reblogs can't be archived (Pixelfed rule).
  """
  @spec archive_local(integer(), Angler.Profiles.Profile.t()) ::
          {:ok, Status.t()} | {:error, atom()}
  def archive_local(status_id, %Angler.Profiles.Profile{id: profile_id})
      when is_integer(status_id) do
    case Repo.get(Status, status_id) do
      nil -> {:error, :not_found}
      %Status{deleted_at: %DateTime{}} -> {:error, :not_found}
      %Status{profile_id: pid} when pid != profile_id -> {:error, :forbidden}
      %Status{local: false} -> {:error, :forbidden}
      %Status{in_reply_to_id: id} when not is_nil(id) -> {:error, :unarchivable}
      %Status{reblog_of_id: id} when not is_nil(id) -> {:error, :unarchivable}
      %Status{scope: "archived"} = s -> {:ok, s}
      %Status{} = status -> do_archive(status)
    end
  end

  defp do_archive(%Status{visibility: vis} = status) do
    {:ok, archived} =
      status
      |> Ecto.Changeset.change(scope: "archived", visibility: :direct)
      |> Repo.update()

    Repo.update_all(
      from(p in Angler.Profiles.Profile, where: p.id == ^status.profile_id),
      inc: [statuses_count: -1]
    )

    %{status_id: status.id, original_scope: Atom.to_string(vis)}
    |> Angler.Statuses.ArchivedSnapshot.changeset()
    |> Repo.insert(on_conflict: :nothing, conflict_target: :status_id)

    {:ok, archived}
  end

  @doc "Restore an archived status to its prior visibility."
  @spec unarchive_local(integer(), Angler.Profiles.Profile.t()) ::
          {:ok, Status.t()} | {:error, atom()}
  def unarchive_local(status_id, %Angler.Profiles.Profile{id: profile_id})
      when is_integer(status_id) do
    case Repo.get(Status, status_id) do
      nil -> {:error, :not_found}
      %Status{profile_id: pid} when pid != profile_id -> {:error, :forbidden}
      %Status{scope: "archived"} = s -> do_unarchive(s)
      %Status{} = s -> {:ok, s}
    end
  end

  defp do_unarchive(%Status{} = status) do
    snap = Repo.get_by(Angler.Statuses.ArchivedSnapshot, status_id: status.id)

    visibility =
      case snap && snap.original_scope do
        "public" -> :public
        "unlisted" -> :unlisted
        "private" -> :private
        "direct" -> :direct
        _ -> :public
      end

    {:ok, restored} =
      status
      |> Ecto.Changeset.change(scope: Atom.to_string(visibility), visibility: visibility)
      |> Repo.update()

    Repo.update_all(
      from(p in Angler.Profiles.Profile, where: p.id == ^status.profile_id),
      inc: [statuses_count: 1]
    )

    if snap, do: Repo.delete(snap)
    {:ok, restored}
  end

  @doc "List archived statuses for `profile_id`, newest-first."
  @spec list_archived(integer(), pos_integer()) :: [Status.t()]
  def list_archived(profile_id, limit \\ 20) do
    Repo.all(
      from s in Status,
        where: s.profile_id == ^profile_id and s.scope == "archived" and is_nil(s.deleted_at),
        order_by: [desc: s.id],
        limit: ^limit
    )
    |> preload_for_render()
  end

  ## Local delete

  @doc """
  Soft-delete a local status owned by `profile`. Decrements the author's
  status counter, then enqueues an outbound `Delete Tombstone` activity
  to the same audience the original post reached.

  Returns `{:ok, status}` (the soft-deleted row) or `{:error, atom()}`.
  """
  @spec delete_local(integer(), Angler.Profiles.Profile.t()) ::
          {:ok, Status.t()} | {:error, :not_found | :forbidden | :already_deleted}
  def delete_local(status_id, %Angler.Profiles.Profile{id: profile_id})
      when is_integer(status_id) do
    case Repo.get(Status, status_id) do
      nil -> {:error, :not_found}
      %Status{deleted_at: %DateTime{}} -> {:error, :already_deleted}
      %Status{profile_id: pid} when pid != profile_id -> {:error, :forbidden}
      %Status{local: false} -> {:error, :forbidden}
      %Status{} = status -> do_delete(status)
    end
  end

  defp do_delete(%Status{} = status) do
    audience = Angler.Statuses.OutboundAudience.inboxes_for(status)

    {:ok, deleted} =
      status |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()

    Repo.update_all(
      from(p in Angler.Profiles.Profile, where: p.id == ^status.profile_id),
      inc: [statuses_count: -1]
    )

    Enum.each(audience, fn inbox_url ->
      Angler.Statuses.Workers.StatusDeleteDeliver.enqueue(deleted.id, inbox_url)
    end)

    Angler.Streaming.broadcast_status_delete(deleted.id, deleted)
    dm_deleted(deleted.id)
    Angler.Quotes.status_deleted(deleted.id)
    {:ok, deleted}
  end

  # A deleted DM leaves its conversation pointing at the newest remaining
  # message, and off unread counts.
  defp dm_deleted(status_id) do
    case Angler.Conversations.conversation_id_for(status_id) do
      nil -> :ok
      cid -> Angler.Conversations.message_deleted(cid, status_id)
    end
  end

  ## Federation-facing writes

  @doc """
  Create a remote status row from an inbound `Create Note` activity.

  Returns `{:ok, status}` or `{:error, reason}`. Idempotent on the AS2 `id`
  (uri unique constraint). `opts[:created_at]` backdates `inserted_at` (a
  backfilled old post).
  """
  @spec create_remote(map(), keyword()) :: {:ok, Status.t()} | {:error, term()}
  def create_remote(attrs, opts \\ []) when is_map(attrs) do
    uri = attr(attrs, :uri)

    # Caller (Statuses.Federation.handle_create/2) checks `get_by_uri` before
    # calling. If a race produces a duplicate insert, the unique constraint
    # raises `Ecto.ConstraintError` (we can't use ON CONFLICT because the
    # `uri` index is partial — `WHERE uri IS NOT NULL` — and PG's ON CONFLICT
    # requires either a non-partial index or a matching predicate clause).
    try do
      Status.changeset(attrs) |> put_timestamps(opts[:created_at]) |> Repo.insert()
    rescue
      Ecto.ConstraintError ->
        case uri && Repo.get_by(Status, uri: uri) do
          %Status{} = existing -> {:ok, existing}
          _ -> {:error, :insert_failed}
        end
    end
  end

  # Callers pass atom- or string-keyed attrs; the atom key wins.
  defp attr(attrs, key), do: attrs[key] || attrs[Atom.to_string(key)]

  @doc """
  Whether a remote `profile` may `:like` or `:announce` `status` (upstream
  96b645980). Public and unlisted posts take both. A followers-only post takes
  a like only from an accepted follower and is never boosted, so a remote boost
  can't fan it into strangers' timelines. Direct posts take neither.
  """
  @spec remote_interaction_allowed?(Status.t(), Angler.Profiles.Profile.t(), :like | :announce) ::
          boolean()
  def remote_interaction_allowed?(%Status{visibility: v}, _profile, _kind)
      when v in [:public, :unlisted],
      do: true

  def remote_interaction_allowed?(%Status{visibility: :private} = status, profile, :like) do
    match?(
      %{accepted_at: %DateTime{}},
      Angler.Follows.get_follower(status.profile_id, profile.id)
    )
  end

  def remote_interaction_allowed?(_status, _profile, _kind), do: false

  @doc "Soft-delete a status by AS2 `id`. Idempotent."
  @spec soft_delete_by_uri(String.t()) :: :ok
  def soft_delete_by_uri(uri) when is_binary(uri) do
    {n, _} =
      from(s in Status, where: s.uri == ^uri and is_nil(s.deleted_at))
      |> Repo.update_all(set: [deleted_at: DateTime.utc_now()])

    if n > 0 do
      decrement_author_count_for(uri)

      case Repo.one(from s in Status, where: s.uri == ^uri, select: s.id) do
        nil -> :ok
        id -> dm_deleted(id)
      end
    end

    :ok
  end

  defp decrement_author_count_for(uri) do
    case Repo.one(from s in Status, where: s.uri == ^uri, select: s.profile_id) do
      nil ->
        :ok

      profile_id ->
        from(p in Angler.Profiles.Profile, where: p.id == ^profile_id)
        |> Repo.update_all(inc: [statuses_count: -1])

        :ok
    end
  end

  @doc "Increment per-status counters atomically."
  @spec inc_counter(integer(), atom(), integer()) :: :ok
  def inc_counter(status_id, field, by \\ 1)
      when field in [:reply_count, :reblogs_count, :likes_count] and is_integer(by) do
    from(s in Status, where: s.id == ^status_id)
    |> Repo.update_all(inc: [{field, by}])

    :ok
  end

  ## Local interactions (favourite / reblog / bookmark)

  alias Angler.Conversations
  alias Angler.Likes
  alias Angler.Media
  alias Angler.Notifications
  alias Angler.Polls
  alias Angler.Reblogs
  alias Angler.Statuses.Workers.InteractionDeliver

  @doc """
  `actor` favourites `status`. Idempotent.

  Returns `{:ok, status}` (reloaded with fresh counters). For remote-author
  statuses, enqueues an outbound `Like` activity to the author's inbox.
  """
  @spec favourite(Profile.t(), Status.t()) :: {:ok, Status.t()} | {:error, term()}
  def favourite(%Profile{} = actor, %Status{} = status) do
    activity_id = mint_interaction_id(actor, "likes")

    case Likes.insert(%{
           profile_id: actor.id,
           status_id: status.id,
           remote_url: activity_id
         }) do
      {:ok, like} ->
        # If the row was freshly inserted (id matches our just-inserted activity_id),
        # bump counters + enqueue federation. If it's a re-favourite of an existing
        # like, do nothing extra.
        if like.remote_url == activity_id do
          inc_counter(status.id, :likes_count, 1)
          maybe_deliver_interaction(:like, actor, status, activity_id)

          Notifications.notify(%{
            recipient_id: status.profile_id,
            account_id: actor.id,
            type: "favourite",
            status_id: status.id
          })
        end

        {:ok, get!(status.id)}

      err ->
        err
    end
  end

  @doc "Undo a favourite. Idempotent."
  @spec unfavourite(Profile.t(), Status.t()) :: {:ok, Status.t()}
  def unfavourite(%Profile{} = actor, %Status{} = status) do
    case Repo.get_by(Angler.Likes.Like, profile_id: actor.id, status_id: status.id) do
      nil ->
        {:ok, get!(status.id)}

      like ->
        Likes.delete(actor.id, status.id)
        inc_counter(status.id, :likes_count, -1)

        if like.remote_url do
          maybe_deliver_interaction_undo(:undo_like, actor, status, like.remote_url)
        end

        {:ok, get!(status.id)}
    end
  end

  @doc """
  `actor` reblogs `status`. Idempotent.

  Returns the original status with `reblogged: true` and incremented count.
  Synthetic-status-row wrapping (Mastodon's full reblog shape) is deferred
  — clients render the original with the reblogged flag for now.
  """
  @spec reblog(Profile.t(), Status.t()) :: {:ok, Status.t()} | {:error, term()}
  def reblog(%Profile{} = actor, %Status{} = status) do
    if status.visibility in [:private, :direct] do
      {:error, :unrebloggable}
    else
      activity_id = mint_interaction_id(actor, "boosts")

      case Reblogs.insert(%{
             profile_id: actor.id,
             status_id: status.id,
             remote_url: activity_id
           }) do
        {:ok, reblog} ->
          if reblog.remote_url == activity_id do
            inc_counter(status.id, :reblogs_count, 1)
            maybe_deliver_interaction(:announce, actor, status, activity_id)
            Angler.Timelines.Workers.FeedInsert.enqueue_reblog(status.id, actor.id)

            Notifications.notify(%{
              recipient_id: status.profile_id,
              account_id: actor.id,
              type: "reblog",
              status_id: status.id
            })
          end

          {:ok, get!(status.id)}

        err ->
          err
      end
    end
  end

  @doc "Undo a reblog. Idempotent."
  @spec unreblog(Profile.t(), Status.t()) :: {:ok, Status.t()}
  def unreblog(%Profile{} = actor, %Status{} = status) do
    case Repo.get_by(Angler.Reblogs.Reblog, profile_id: actor.id, status_id: status.id) do
      nil ->
        {:ok, get!(status.id)}

      reblog ->
        Reblogs.delete(actor.id, status.id)
        inc_counter(status.id, :reblogs_count, -1)

        if reblog.remote_url do
          maybe_deliver_interaction_undo(:undo_announce, actor, status, reblog.remote_url)
        end

        {:ok, get!(status.id)}
    end
  end

  @doc """
  Profiles who favourited `status_id`, newest first. Backs the "who liked this"
  disclosure on the web detail page.
  """
  @spec list_likers(integer(), keyword()) :: [Profile.t()]
  def list_likers(status_id, opts \\ []) when is_integer(status_id) do
    limit = Keyword.get(opts, :limit, 60)

    from(l in Angler.Likes.Like,
      where: l.status_id == ^status_id,
      join: p in Profile,
      on: p.id == l.profile_id,
      order_by: [desc: l.id],
      limit: ^limit,
      select: p
    )
    |> Repo.all()
  end

  @doc """
  Profiles who reblogged/boosted `status_id`, newest first. Backs the "who
  boosted this" disclosure on the web detail page.
  """
  @spec list_boosters(integer(), keyword()) :: [Profile.t()]
  def list_boosters(status_id, opts \\ []) when is_integer(status_id) do
    limit = Keyword.get(opts, :limit, 60)

    from(r in Angler.Reblogs.Reblog,
      where: r.status_id == ^status_id,
      join: p in Profile,
      on: p.id == r.profile_id,
      order_by: [desc: r.id],
      limit: ^limit,
      select: p
    )
    |> Repo.all()
  end

  ## Internals

  defp get!(id), do: Repo.get!(Status, id) |> Repo.preload(:profile)

  defp mint_interaction_id(%Profile{username: username}, kind) do
    nonce = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    AnglerWeb.Endpoint.url() <> "/users/" <> username <> "/" <> kind <> "/" <> nonce
  end

  defp maybe_deliver_interaction(verb, %Profile{} = actor, %Status{} = status, activity_id) do
    with {:ok, author} <- author_for_delivery(status),
         %Profile{domain: domain} when not is_nil(domain) <- author do
      InteractionDeliver.enqueue(verb, %{
        local_actor_id: actor.id,
        inbox_url: author.shared_inbox_url || author.inbox_url,
        activity_id: activity_id,
        target_uri: status.uri || status.url
      })
    else
      _ -> :ok
    end
  end

  defp maybe_deliver_interaction_undo(verb, %Profile{} = actor, %Status{} = status, original_id) do
    with {:ok, author} <- author_for_delivery(status),
         %Profile{domain: domain} when not is_nil(domain) <- author do
      undo_id = mint_interaction_id(actor, "undos")

      InteractionDeliver.enqueue(verb, %{
        local_actor_id: actor.id,
        inbox_url: author.shared_inbox_url || author.inbox_url,
        activity_id: undo_id,
        original_id: original_id,
        target_uri: status.uri || status.url
      })
    else
      _ -> :ok
    end
  end

  defp author_for_delivery(%Status{profile_id: pid}) do
    case Repo.get(Profile, pid) do
      nil -> {:error, :no_author}
      profile -> {:ok, profile}
    end
  end

  ## Local-author writes

  @doc """
  Create a local status authored by `profile`.

  Required keys in `attrs`:
    * `:status` — caption text (string)

  Optional keys (Mastodon spec):
    * `:in_reply_to_id` — integer status id
    * `:sensitive` — bool
    * `:spoiler_text` — string
    * `:visibility` — `"public" | "unlisted" | "private" | "direct"`, defaults `"public"`
    * `:language` — string

  Returns `{:ok, status}` (preloaded with profile + mentions + hashtags) or
  `{:error, atom() | Ecto.Changeset.t()}`.

  Side effects: caption → HTML render, mention/hashtag association inserts,
  reply parent counter bump, author counter + last_status_at bump. Caller
  is responsible for kicking off `FeedInsert` and outbound federation.

  ## Options

    * `:id` — explicit snowflake id to use instead of minting a fresh one. Used
      by the importer to assign a backdated, collision-free id.
    * `:created_at` — `DateTime` to stamp as `inserted_at`/`updated_at` instead
      of "now". Backdates imported posts.
    * `:broadcast` — set `false` to skip the live-streaming broadcast (default
      `true`). Bulk backfills pass `false` to avoid flooding connected clients.
  """
  @spec create_local(Profile.t(), map(), keyword()) ::
          {:ok, Status.t()} | {:error, atom() | Ecto.Changeset.t()}
  def create_local(profile, attrs, opts \\ [])

  def create_local(%Profile{domain: nil} = profile, attrs, opts) when is_map(attrs) do
    attrs = stringify(attrs)
    media_ids = parse_media_ids(attrs["media_ids"])
    broadcast? = Keyword.get(opts, :broadcast, true)

    with {:ok, caption} <- fetch_caption(attrs, media_ids),
         {:ok, visibility} <- parse_visibility(attrs["visibility"]),
         {:ok, quote_policy} <- parse_quote_policy(attrs),
         {:ok, parent} <- resolve_reply_parent(attrs["in_reply_to_id"], profile.id) do
      draft = %{
        caption: caption,
        lex: Lexer.render(caption),
        visibility: visibility,
        sensitive?: truthy?(attrs["sensitive"]),
        attrs: Map.put(attrs, "quote_policy", quote_policy),
        parent: parent,
        media_ids: media_ids,
        id: Keyword.get(opts, :id),
        created_at: Keyword.get(opts, :created_at)
      }

      Repo.transaction(fn ->
        case insert_status(profile, draft) do
          {:ok, status} -> finish_local_create!(profile, status, draft, broadcast?)
          {:error, %Ecto.Changeset{} = cs} -> Repo.rollback(cs)
        end
      end)
    end
  end

  def create_local(%Profile{}, _, _), do: {:error, :not_local_profile}

  # Inside create_local's transaction, once the status row is in: media,
  # mentions, hashtags, poll and counters. Returns the preloaded status.
  defp finish_local_create!(profile, status, draft, broadcast?) do
    %{lex: lex, visibility: visibility, parent: parent} = draft

    case Media.attach_to_status(draft.media_ids, status.id, profile.id) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    insert_mentions(status, lex.mention_profile_ids)
    insert_hashtags(status, lex.hashtag_names, visibility)

    case attach_poll(status, draft.attrs["poll"]) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    bump_author!(profile.id)
    if parent, do: inc_counter(parent.id, :reply_count)

    loaded = preload_local(status)
    if visibility == :direct, do: Conversations.record(loaded)
    if broadcast?, do: Angler.Streaming.broadcast_status_update(loaded)

    loaded
  end

  defp attach_poll(_status, nil), do: :ok

  defp attach_poll(%Status{} = status, %{"options" => _} = poll_attrs) do
    case Polls.create(status, poll_attrs) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp attach_poll(_, _), do: :ok

  ## Internals — local create

  defp fetch_caption(attrs, media_ids) do
    case Map.get(attrs, "status", "") do
      "" when media_ids != [] -> {:ok, ""}
      "" -> {:error, :empty_status}
      s when is_binary(s) -> {:ok, s}
      _ -> {:error, :bad_caption}
    end
  end

  defp parse_media_ids(nil), do: []
  defp parse_media_ids([]), do: []

  defp parse_media_ids(ids) when is_list(ids) do
    Enum.flat_map(ids, fn
      n when is_integer(n) ->
        [n]

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} -> [n]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp parse_media_ids(_), do: []

  # Mastodon 4.5's `quote_approval_policy`; absent or null = account default.
  defp parse_quote_policy(attrs) do
    case Angler.Quotes.from_api_policy(attrs["quote_approval_policy"]) do
      {:ok, flags} -> {:ok, flags}
      :error -> {:error, :bad_quote_policy}
    end
  end

  defp parse_visibility(nil), do: {:ok, :public}

  defp parse_visibility(v) when v in ["public", "unlisted", "private", "direct"],
    do: {:ok, String.to_existing_atom(v)}

  defp parse_visibility(_), do: {:error, :bad_visibility}

  defp resolve_reply_parent(nil, _viewer), do: {:ok, nil}
  defp resolve_reply_parent("", _viewer), do: {:ok, nil}

  defp resolve_reply_parent(id, viewer) when is_integer(id) do
    case get(id) do
      nil ->
        {:error, :reply_parent_not_found}

      parent ->
        if visible_to?(parent, viewer),
          do: {:ok, parent},
          else: {:error, :reply_parent_not_visible}
    end
  end

  defp resolve_reply_parent(id, viewer) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> resolve_reply_parent(n, viewer)
      _ -> {:error, :bad_reply_parent_id}
    end
  end

  defp insert_status(profile, draft) do
    %{
      caption: caption,
      lex: lex,
      visibility: visibility,
      sensitive?: sensitive?,
      attrs: attrs,
      parent: parent,
      media_ids: media_ids,
      id: id,
      created_at: created_at
    } = draft

    snowflake = id || Angler.Snowflake.next()
    base = AnglerWeb.Endpoint.url()
    canonical = base <> "/p/" <> profile.username <> "/" <> Integer.to_string(snowflake)
    type = type_for(media_ids)

    %{
      id: snowflake,
      profile_id: profile.id,
      caption: caption,
      rendered: lex.html,
      is_nsfw: sensitive?,
      cw_summary: attrs["spoiler_text"],
      visibility: visibility,
      scope: Atom.to_string(visibility),
      type: type,
      pf_type: type,
      local: true,
      uri: canonical,
      url: canonical,
      in_reply_to_id: parent && parent.id,
      in_reply_to_profile_id: parent && parent.profile_id,
      language: attrs["language"] || "en",
      group_id: parse_group_id(attrs["group_id"]),
      quote_policy: attrs["quote_policy"]
    }
    |> Status.changeset()
    |> put_timestamps(created_at)
    |> Repo.insert()
  end

  defp put_timestamps(changeset, nil), do: changeset

  defp put_timestamps(changeset, %DateTime{} = created_at) do
    Ecto.Changeset.change(changeset, inserted_at: created_at, updated_at: created_at)
  end

  defp parse_group_id(nil), do: nil
  defp parse_group_id(n) when is_integer(n), do: n

  defp parse_group_id(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_group_id(_), do: nil

  defp type_for([]), do: "text"
  defp type_for([_]), do: "photo"
  defp type_for(_), do: "photo:album"

  defp insert_mentions(_status, []), do: :ok

  # A DM's recipients are notified by `Conversations.record/1` instead.
  defp insert_mentions(%Status{id: status_id, profile_id: author_id} = status, profile_ids) do
    rows =
      for pid <- profile_ids, pid != nil do
        %{status_id: status_id, profile_id: pid, silent: false, inserted_at: DateTime.utc_now()}
      end

    if rows != [] do
      Repo.insert_all(Mention, rows,
        on_conflict: :nothing,
        conflict_target: [:status_id, :profile_id]
      )

      for pid <- profile_ids, pid != nil and pid != author_id and status.visibility != :direct do
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

  defp insert_hashtags(_status, [], _visibility), do: :ok

  defp insert_hashtags(%Status{id: status_id, profile_id: profile_id}, names, visibility) do
    Enum.each(names, fn name ->
      tag = Hashtags.ensure!(name)

      %{
        status_id: status_id,
        hashtag_id: tag.id,
        profile_id: profile_id,
        status_visibility: Atom.to_string(visibility),
        inserted_at: DateTime.utc_now()
      }
      |> StatusHashtag.changeset()
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:status_id, :hashtag_id])
    end)

    :ok
  end

  defp bump_author!(profile_id) do
    Repo.update_all(
      from(p in Profile, where: p.id == ^profile_id),
      inc: [statuses_count: 1],
      set: [last_status_at: DateTime.utc_now()]
    )

    :ok
  end

  defp preload_local(%Status{} = s) do
    Repo.preload(s, [:profile, :mentions, status_hashtags: :hashtag])
  end

  defp stringify(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false
end
