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

  @doc "Get a non-deleted status by AS2 `id` / `uri`."
  @spec get_by_uri(String.t()) :: Status.t() | nil
  def get_by_uri(uri) when is_binary(uri) do
    Status
    |> where([s], s.uri == ^uri and is_nil(s.deleted_at))
    |> preload(:profile)
    |> Repo.one()
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

  ## Federation-facing writes

  @doc """
  Create a remote status row from an inbound `Create Note` activity.

  Returns `{:ok, status}` or `{:error, reason}`. Idempotent on the AS2 `id`
  (uri unique constraint).
  """
  @spec create_remote(map()) :: {:ok, Status.t()} | {:error, term()}
  def create_remote(attrs) when is_map(attrs) do
    uri = attrs[:uri] || attrs["uri"]

    # Caller (Statuses.Federation.handle_create/2) checks `get_by_uri` before
    # calling. If a race produces a duplicate insert, the unique constraint
    # raises `Ecto.ConstraintError` (we can't use ON CONFLICT because the
    # `uri` index is partial — `WHERE uri IS NOT NULL` — and PG's ON CONFLICT
    # requires either a non-partial index or a matching predicate clause).
    try do
      Status.changeset(attrs) |> Repo.insert()
    rescue
      Ecto.ConstraintError ->
        case uri && Repo.get_by(Status, uri: uri) do
          %Status{} = existing -> {:ok, existing}
          _ -> {:error, :insert_failed}
        end
    end
  end

  @doc "Soft-delete a status by AS2 `id`. Idempotent."
  @spec soft_delete_by_uri(String.t()) :: :ok
  def soft_delete_by_uri(uri) when is_binary(uri) do
    {n, _} =
      from(s in Status, where: s.uri == ^uri and is_nil(s.deleted_at))
      |> Repo.update_all(set: [deleted_at: DateTime.utc_now()])

    if n > 0, do: decrement_author_count_for(uri)
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

  alias Angler.Likes
  alias Angler.Media
  alias Angler.Notifications
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
  """
  @spec create_local(Profile.t(), map()) ::
          {:ok, Status.t()} | {:error, atom() | Ecto.Changeset.t()}
  def create_local(%Profile{domain: nil} = profile, attrs) when is_map(attrs) do
    attrs = stringify(attrs)
    media_ids = parse_media_ids(attrs["media_ids"])

    with {:ok, caption} <- fetch_caption(attrs, media_ids),
         {:ok, visibility} <- parse_visibility(attrs["visibility"]),
         {:ok, parent} <- resolve_reply_parent(attrs["in_reply_to_id"], profile.id) do
      lex = Lexer.render(caption)
      sensitive? = truthy?(attrs["sensitive"])

      Repo.transaction(fn ->
        case insert_status(
               profile,
               caption,
               lex,
               visibility,
               sensitive?,
               attrs,
               parent,
               media_ids
             ) do
          {:ok, status} ->
            case Media.attach_to_status(media_ids, status.id, profile.id) do
              {:ok, _} -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end

            insert_mentions(status, lex.mention_profile_ids)
            insert_hashtags(status, lex.hashtag_names, visibility)
            bump_author!(profile.id)
            if parent, do: inc_counter(parent.id, :reply_count)

            preload_local(status)

          {:error, %Ecto.Changeset{} = cs} ->
            Repo.rollback(cs)
        end
      end)
    end
  end

  def create_local(%Profile{}, _), do: {:error, :not_local_profile}

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

  defp insert_status(profile, caption, lex, visibility, sensitive?, attrs, parent, media_ids) do
    snowflake = Angler.Snowflake.next()
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
      language: attrs["language"] || "en"
    }
    |> Status.changeset()
    |> Repo.insert()
  end

  defp type_for([]), do: "text"
  defp type_for([_]), do: "photo"
  defp type_for(_), do: "photo:album"

  defp insert_mentions(_status, []), do: :ok

  defp insert_mentions(%Status{id: status_id, profile_id: author_id}, profile_ids) do
    rows =
      for pid <- profile_ids, pid != nil do
        %{status_id: status_id, profile_id: pid, silent: false, inserted_at: DateTime.utc_now()}
      end

    if rows != [] do
      Repo.insert_all(Mention, rows,
        on_conflict: :nothing,
        conflict_target: [:status_id, :profile_id]
      )

      for pid <- profile_ids, pid != nil and pid != author_id do
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
