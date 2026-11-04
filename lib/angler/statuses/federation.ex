defmodule Angler.Statuses.Federation do
  @moduledoc """
  Inbound activity handlers for Note-related verbs:
  `Create Note`, `Update Note`, `Delete Tombstone`.

  AS2 → `Status` row, including mentions and hashtags from the object's
  `tag` array. Local recipients of mentions are resolved by URL match
  against `<base>/users/<name>`.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Angler.Conversations
  alias Angler.Federation.Actor
  alias Angler.Federation.HTTP
  alias Angler.Federation.InstanceActor
  alias Angler.Hashtags
  alias Angler.Notifications
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses
  alias Angler.Statuses.{Mention, Status, StatusHashtag}

  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  @doc """
  Handle a `Create` activity whose `object.type` is `Note` (or `Question`).

  Returns `:ok` on success or `{:error, reason}`. Idempotent on object id.
  """
  @spec handle_create(map(), String.t()) :: :ok | {:error, term()}
  def handle_create(%{"object" => %{"type" => type, "id" => object_id} = object}, actor_url)
      when type in ["Note", "Question"] and is_binary(object_id) do
    cond do
      not authored_by?(object, actor_url) -> {:error, :not_authored_by_actor}
      # Already mirrored.
      Statuses.get_by_uri(object_id) -> :ok
      true -> do_create(object, actor_url)
    end
  end

  def handle_create(_, _), do: {:error, :unsupported_object_type}

  # An actor may only deliver objects it wrote, hosted on its own server —
  # otherwise a forged `id` could squat another server's (or a local) URI.
  defp authored_by?(%{"id" => id} = object, actor_url) do
    Actor.same_actor?(attributed_to(object), actor_url) and Actor.same_host?(id, actor_url)
  end

  defp attributed_to(%{"attributedTo" => a}) when is_binary(a), do: a
  defp attributed_to(%{"attributedTo" => %{"id" => a}}) when is_binary(a), do: a

  defp attributed_to(%{"attributedTo" => list}) when is_list(list) do
    Enum.find_value(list, fn
      a when is_binary(a) -> a
      %{"id" => a, "type" => "Person"} -> a
      _ -> nil
    end)
  end

  defp attributed_to(_), do: nil

  @doc """
  Ingest the object of a relay-forwarded `Announce` as an ordinary public
  remote status.

  Unlike a user boost (handled by `Angler.Reblogs.Federation`), a relay
  firehose `Announce` carries a Note we don't have yet — usually a bare URI.
  We fetch it (signed with the instance actor, since some servers require
  signed object fetches) and run the normal `Create` path. Idempotent on the
  object id. Callers must gate this on `Relays.relay_actor?/1`.
  """
  @spec ingest_announced(map()) :: :ok | {:error, term()}
  def ingest_announced(%{"object" => object}) do
    with {:ok, url} <- announced_object_url(object),
         {:ok, %{"type" => type, "id" => id} = note}
         when type in ["Note", "Question"] and is_binary(id) <- fetch_announced(url),
         # The doc must be the object we asked for, by an author on its host.
         true <- Actor.same_actor?(id, url),
         author when is_binary(author) <- attributed_to(note),
         true <- Actor.same_host?(id, author) do
      case Statuses.get_by_uri(id) do
        %Status{} -> :ok
        nil -> do_create(note, author)
      end
    else
      _ -> {:error, :unprocessable_announce}
    end
  end

  def ingest_announced(_), do: {:error, :bad_announce}

  @doc """
  Fetch a remote status by its AS2 object URL and mirror it locally.

  The discovery counterpart to `ingest_announced/1`: used by the Beagle
  network-trending poller (`Angler.Discover.Workers.BeagleDiscover`) to pull in
  curated cross-instance posts. Signed fetch with the instance actor, idempotent
  on the object id, and subject to the same SSRF/banned-domain guards as every
  other outbound fetch (via `Angler.Federation.HTTP`).
  """
  @spec fetch_and_ingest(String.t()) :: :ok | {:error, term()}
  def fetch_and_ingest(url) when is_binary(url), do: ingest_announced(%{"object" => url})

  # A relay's inline copy is unauthenticated — the relay didn't write it — so
  # we always fetch the object from its origin.
  defp announced_object_url(%{"id" => url}) when is_binary(url), do: {:ok, url}
  defp announced_object_url(url) when is_binary(url), do: {:ok, url}
  defp announced_object_url(_), do: {:error, :bad_object}

  defp fetch_announced(url) do
    actor = InstanceActor.ensure!()
    HTTP.fetch(url, signed_with: {actor.key_id, actor.private_key_pem})
  end

  defp do_create(object, actor_url) do
    with {:ok, %Profile{} = author} <- Actor.resolve(actor_url),
         attrs = build_attrs(object, author),
         {:ok, status} <- Statuses.create_remote(attrs) do
      attach_media(status, object)
      attach_mentions(status, object)
      attach_hashtags(status, object)
      bump_author_count(status.profile_id)
      maybe_increment_reply_count(status)
      adopt_replies(status)

      if status.visibility == :direct, do: Conversations.record(status)

      # Fan into local followers' home timelines. Skips :direct visibility.
      Angler.Timelines.Workers.FeedInsert.enqueue(status.id)

      :ok
    else
      {:error, %Ecto.Changeset{} = cs} ->
        Logger.warning("inbound Create Note rejected: #{inspect(cs.errors)}")
        {:error, :invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Handle `Update Note` — refresh mutable fields on an already-mirrored status.

  Mastodon includes the full updated Note inline; we trust it.
  """
  @spec handle_update(map(), String.t()) :: :ok | {:error, term()}
  def handle_update(%{"object" => %{"type" => type, "id" => object_id} = object}, actor_url)
      when type in ["Note", "Question"] and is_binary(object_id) do
    case Statuses.get_by_uri(object_id) do
      nil ->
        # Update for an unknown status — could indicate we missed the Create.
        # Materialize it as one, under the same authorship rules.
        Logger.info("Update Note for unknown status #{object_id}; treating as Create")
        handle_create(%{"object" => object}, actor_url)

      %Status{} = status ->
        if remote_owned_by?(status, actor_url),
          do: apply_update(status, object),
          else: {:error, :not_owner}
    end
  end

  def handle_update(_, _), do: {:error, :bad_update_payload}

  defp apply_update(%Status{} = status, object) do
    edited_at =
      with ts when is_binary(ts) <- object["updated"],
           {:ok, dt, _} <- DateTime.from_iso8601(ts) do
        dt
      else
        _ -> DateTime.utc_now()
      end

    attrs = build_attrs(object, status.profile) |> Map.put(:edited_at, edited_at)

    case status |> Status.changeset(attrs) |> Repo.update() do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Handle `Delete Tombstone` — soft-delete the mirrored status, but only when
  `actor_url` authored it. Local statuses are never deleted from outside.
  """
  @spec handle_delete_tombstone(String.t(), String.t()) :: :ok
  def handle_delete_tombstone(object_id, actor_url)
      when is_binary(object_id) and is_binary(actor_url) do
    case Statuses.get_by_uri(object_id) do
      %Status{} = status ->
        if remote_owned_by?(status, actor_url), do: Statuses.soft_delete_by_uri(object_id)
        :ok

      nil ->
        :ok
    end
  end

  defp remote_owned_by?(%Status{local: false, profile: %Profile{remote_url: owner}}, actor_url),
    do: Actor.same_actor?(owner, actor_url)

  defp remote_owned_by?(_, _), do: false

  ## Internals

  defp build_attrs(object, %Profile{} = author) do
    visibility = visibility_from_audience(object, author.followers_url)

    %{
      profile_id: author.id,
      caption: strip_html(object["content"] || ""),
      rendered: object["content"] || "",
      is_nsfw: object["sensitive"] == true,
      cw_summary: object["summary"],
      visibility: visibility,
      scope: Atom.to_string(visibility),
      type: type_from_attachments(object["attachment"]),
      pf_type: type_from_attachments(object["attachment"]),
      local: false,
      uri: object["id"],
      url: object["url"] || object["id"],
      in_reply_to_id: lookup_reply_target_id(object),
      in_reply_to_profile_id: lookup_reply_target_author_id(object),
      in_reply_to_uri: reply_uri(object),
      language: language_of(object)
    }
  end

  # `to`/`cc` mapping (Mastodon convention):
  #   to:[Public], cc:[followers] → :public
  #   to:[followers], cc:[] → :unlisted (Public missing, only followers)
  #   to:[mentions], cc:[] → :direct
  #   else → :private (only followers / locked)
  # Any followers collection in the audience makes it followers-only, even
  # with mentions alongside: Mastodon addresses a followers-only post that
  # mentions someone as to:[followers], cc:[mention], and that used to be
  # stored as a DM. No audience at all is not public — keep it to the
  # author and anyone named (upstream drops such notes).
  defp visibility_from_audience(object, followers_url) do
    to = List.wrap(object["to"])
    cc = List.wrap(object["cc"])
    all = to ++ cc

    cond do
      @public_uri in to -> :public
      @public_uri in cc -> :unlisted
      Enum.any?(all, &followers_collection?(&1, followers_url)) -> :private
      true -> :direct
    end
  end

  defp followers_collection?(uri, followers_url) when is_binary(uri),
    do: uri == followers_url or String.ends_with?(uri, "/followers")

  defp followers_collection?(_, _), do: false

  defp type_from_attachments(atts) when is_list(atts) and atts != [] do
    atts |> Enum.map(&media_kind/1) |> Enum.uniq() |> attachments_type(match?([_], atts))
  end

  defp type_from_attachments(_), do: "text"

  # The distinct kinds among a post's attachments, and whether it has just one.
  defp attachments_type([:image], true), do: "photo"
  defp attachments_type([:image], false), do: "photo:album"
  defp attachments_type([:video], true), do: "video"
  defp attachments_type([:video], false), do: "video:album"

  defp attachments_type(kinds, _single?) do
    if Enum.all?(kinds, &(&1 in [:image, :video])), do: "photo:video:album", else: "text"
  end

  defp media_kind(%{"mediaType" => mt}) when is_binary(mt) do
    cond do
      String.starts_with?(mt, "image/") -> :image
      String.starts_with?(mt, "video/") -> :video
      true -> :other
    end
  end

  defp media_kind(_), do: :other

  defp language_of(%{"contentMap" => %{} = map}) do
    case Map.keys(map) do
      [first | _] -> first
      _ -> "en"
    end
  end

  defp language_of(_), do: "en"

  defp reply_uri(%{"inReplyTo" => uri}) when is_binary(uri) and uri != "", do: uri
  defp reply_uri(%{"inReplyTo" => %{"id" => uri}}) when is_binary(uri) and uri != "", do: uri
  defp reply_uri(_), do: nil

  defp lookup_reply_target_id(%{"inReplyTo" => uri}) when is_binary(uri) do
    case Statuses.get_by_uri(uri) do
      %Status{id: id} -> id
      _ -> nil
    end
  end

  defp lookup_reply_target_id(_), do: nil

  defp lookup_reply_target_author_id(%{"inReplyTo" => uri}) when is_binary(uri) do
    case Statuses.get_by_uri(uri) do
      %Status{profile_id: pid} -> pid
      _ -> nil
    end
  end

  defp lookup_reply_target_author_id(_), do: nil

  ## Tag processing

  defp attach_media(%Status{} = status, object) do
    Angler.Media.ingest_remote_attachments(
      List.wrap(object["attachment"]),
      status.id,
      status.profile_id
    )

    :ok
  end

  defp attach_mentions(%Status{} = status, %{"tag" => tags}) when is_list(tags) do
    base_users = AnglerWeb.Endpoint.url() <> "/users/"

    tags
    |> Enum.filter(&(&1["type"] == "Mention" and is_binary(&1["href"])))
    |> Enum.map(& &1["href"])
    |> Enum.uniq()
    |> Enum.each(&attach_mention(status, &1, base_users))
  end

  defp attach_mentions(_, _), do: :ok

  defp attach_mention(%Status{} = status, href, base_users) do
    if String.starts_with?(href, base_users) do
      attach_local_mention(status, String.trim_leading(href, base_users))
    else
      # Remote mention — store iff we already have the actor cached.
      # We deliberately don't fetch here to avoid amplification.
      case Repo.get_by(Profile, remote_url: href) do
        %Profile{id: pid} -> insert_mention(status.id, pid)
        _ -> :ok
      end
    end
  end

  defp attach_local_mention(%Status{} = status, username) do
    case Profiles.get_local_by_username(username) do
      %Profile{id: pid} ->
        insert_mention(status.id, pid)

        # A DM's recipients are notified by `Conversations.record/1`.
        if status.visibility != :direct do
          Notifications.notify(%{
            recipient_id: pid,
            account_id: status.profile_id,
            type: "mention",
            status_id: status.id
          })
        end

      _ ->
        :ok
    end
  end

  defp insert_mention(status_id, profile_id) do
    %{status_id: status_id, profile_id: profile_id}
    |> Mention.changeset()
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:status_id, :profile_id])
  end

  defp attach_hashtags(%Status{} = status, %{"tag" => tags}) when is_list(tags) do
    tags
    |> Enum.filter(&(&1["type"] == "Hashtag" and is_binary(&1["name"])))
    |> Enum.map(&hashtag_name/1)
    |> Enum.uniq()
    |> Enum.each(fn name ->
      tag = Hashtags.ensure!(name)

      %{
        status_id: status.id,
        hashtag_id: tag.id,
        profile_id: status.profile_id,
        status_visibility: Atom.to_string(status.visibility)
      }
      |> StatusHashtag.changeset()
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:status_id, :hashtag_id])
    end)
  end

  defp attach_hashtags(_, _), do: :ok

  # `name` may come as `#tag` or `tag` — strip the leading `#`.
  defp hashtag_name(%{"name" => name}) do
    name |> String.trim_leading("#") |> String.downcase()
  end

  ## Counter housekeeping

  defp bump_author_count(profile_id) do
    Repo.update_all(
      from(p in Profile, where: p.id == ^profile_id),
      inc: [statuses_count: 1],
      set: [last_status_at: DateTime.utc_now()]
    )

    :ok
  end

  # Replies that arrived before this post did: point them at it now.
  defp adopt_replies(%Status{uri: uri} = status) when is_binary(uri) do
    {n, _} =
      Repo.update_all(
        from(s in Status, where: s.in_reply_to_uri == ^uri and is_nil(s.in_reply_to_id)),
        set: [in_reply_to_id: status.id, in_reply_to_profile_id: status.profile_id]
      )

    if n > 0,
      do: Repo.update_all(from(s in Status, where: s.id == ^status.id), inc: [reply_count: n])

    :ok
  end

  defp adopt_replies(_), do: :ok

  defp maybe_increment_reply_count(%Status{in_reply_to_id: nil}), do: :ok

  defp maybe_increment_reply_count(%Status{in_reply_to_id: parent}),
    do: Statuses.inc_counter(parent, :reply_count)

  ## Plain-text caption from HTML — minimal Floki-free version.
  defp strip_html(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/&nbsp;/, " ")
    |> String.replace(~r/&amp;/, "&")
    |> String.replace(~r/&lt;/, "<")
    |> String.replace(~r/&gt;/, ">")
    |> String.replace(~r/&quot;/, "\"")
    |> String.replace(~r/&#39;/, "'")
    |> String.trim()
  end

  defp strip_html(_), do: ""
end
