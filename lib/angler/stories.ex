defmodule Angler.Stories do
  @moduledoc """
  Pixelfed-style ephemeral stories: 24h media tiles, view-tracking, optional
  reply-as-DM. Toggled at runtime via `:stories_enabled` config (default
  `false` — operators opt in).

  ## Lifecycle

    1. `add/3` uploads media into a draft (`active: false`) story owned by
       the caller. There's a per-day cap (Pixelfed's 30) to prevent abuse.
    2. `publish/3` flips `active: true` and sets `expires_at = now + 24h`.
    3. `mark_seen/2` is idempotent and bumps `view_count` only on the first
       insert per `(story, viewer)`.
    4. `Workers.Expire` runs every minute and flips `active: false` on
       any story whose `expires_at` is in the past.
    5. `delete/2` author-only force-expires.

  Replies and reactions become `story:reply` / `story:reaction` `:direct`
  statuses to the author, carrying the `story_id` — see `comment/3` and
  `react/3`. Publishing, deleting, expiring, viewing and answering federate
  through `Angler.Stories.Outbound`.
  """

  import Ecto.Query, warn: false

  alias Angler.Follows.Follower
  alias Angler.Media.Storage
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses
  alias Angler.Statuses.{Mention, Status}
  alias Angler.Stories.{Outbound, RemoteMedia, Story, View}

  @max_per_day 30
  @ttl_seconds 24 * 60 * 60

  @image_mimes ~w(image/jpeg image/png)
  @video_mimes ~w(video/mp4)

  @doc "Whether the operator has enabled the stories feature."
  def enabled?, do: Angler.Instance.toggle(:stories_enabled, false)

  ## Add (upload draft)

  @spec add(Profile.t(), map(), map()) :: {:ok, Story.t()} | {:error, atom()}
  def add(%Profile{} = author, upload, params \\ %{}) do
    cond do
      not enabled?() ->
        {:error, :disabled}

      active_today_count(author.id) >= @max_per_day ->
        {:error, :limit_reached}

      true ->
        do_add(author, upload, params)
    end
  end

  defp do_add(%Profile{} = author, upload, params) do
    src = Map.get(upload, :path)
    declared = Map.get(upload, :content_type)

    cond do
      not is_binary(src) or not File.exists?(src) ->
        {:error, :no_file}

      not (declared in @image_mimes or declared in @video_mimes) ->
        {:error, :unsupported_type}

      true ->
        ext = ext_for(declared)
        sha = sha256(src)
        filename = "story-" <> Base.encode16(sha, case: :lower) <> "." <> ext
        {:ok, stored_path} = Storage.put(author.id, :story, filename, src)

        type = if declared in @video_mimes, do: "video", else: "photo"
        duration_ms = parse_duration_ms(params["duration"])

        attrs = %{
          profile_id: author.id,
          type: type,
          mime: declared,
          path: stored_path,
          duration_ms: duration_ms,
          # Default `expires_at` lives one day out even on the draft so a
          # forgotten draft doesn't dangle forever.
          expires_at: DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)
        }

        %Story{} |> Story.changeset(attrs) |> Repo.insert()
    end
  end

  defp active_today_count(profile_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -1 * @ttl_seconds, :second)

    Repo.aggregate(
      from(s in Story,
        where: s.profile_id == ^profile_id and s.inserted_at >= ^cutoff
      ),
      :count
    )
  end

  ## Publish

  @spec publish(Profile.t(), integer(), map()) :: {:ok, Story.t()} | {:error, atom()}
  def publish(%Profile{} = author, story_id, params) when is_integer(story_id) do
    case Repo.get_by(Story, id: story_id, profile_id: author.id) do
      nil ->
        {:error, :not_found}

      story ->
        story
        |> Ecto.Changeset.change(
          active: true,
          can_reply: truthy?(params["can_reply"], story.can_reply),
          can_react: truthy?(params["can_react"], story.can_react),
          duration_ms: parse_duration_ms(params["duration"], story.duration_ms),
          bearcap_token: story.bearcap_token || mint_bearcap(),
          expires_at: DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)
        )
        |> Repo.update()
        |> tap(&fan_out_published/1)
    end
  end

  defp fan_out_published({:ok, %Story{} = story}), do: Outbound.published(story)
  defp fan_out_published(_), do: :ok

  defp mint_bearcap do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  ## Carousel reads

  @doc """
  Pixelfed-shape `{self, nodes}` envelope:

    * `self` — viewer's own active stories (or `[]` when none).
    * `nodes` — active stories from accounts the viewer follows, grouped
      by author. Sorted with unseen-first.
  """
  @spec carousel(Profile.t()) :: %{self: list(), nodes: list()}
  def carousel(%Profile{id: viewer_id}) do
    %{self: own_carousel(viewer_id), nodes: feed_nodes(viewer_id)}
  end

  defp own_carousel(viewer_id) do
    case active_stories_for(viewer_id) do
      [] ->
        []

      list ->
        profile = Repo.get!(Profile, viewer_id)

        %{
          "user" => render_user(profile, viewer_id),
          "nodes" => Enum.map(list, &render_node(&1, viewer_id))
        }
    end
  end

  defp feed_nodes(viewer_id) do
    follow_ids =
      Repo.all(
        from f in Follower,
          where: f.following_id == ^viewer_id and not is_nil(f.accepted_at),
          select: f.profile_id
      )

    if follow_ids == [] do
      []
    else
      now = DateTime.utc_now()

      stories =
        Repo.all(
          from s in Story,
            where: s.profile_id in ^follow_ids and s.active == true and s.expires_at > ^now,
            order_by: [asc: s.id]
        )
        |> Repo.preload(:profile)

      seen_ids = seen_set(viewer_id, Enum.map(stories, & &1.id))

      stories
      |> Enum.group_by(& &1.profile_id)
      |> Enum.map(fn {pid, list} ->
        author = hd(list).profile

        %{
          "id" => "pfs:#{pid}",
          "user" => render_user(author, viewer_id),
          "nodes" =>
            Enum.map(list, fn s ->
              render_node(s, viewer_id, MapSet.member?(seen_ids, s.id))
            end),
          "url" => Angler.Profiles.url(author),
          "seen" => Enum.all?(list, &MapSet.member?(seen_ids, &1.id))
        }
      end)
      |> Enum.sort_by(& &1["seen"])
    end
  end

  @doc "Whether the profile has a live (published, unexpired) story."
  @spec has_active?(integer()) :: boolean()
  def has_active?(profile_id) when is_integer(profile_id) do
    now = DateTime.utc_now()

    Repo.exists?(
      from s in Story,
        where: s.profile_id == ^profile_id and s.active == true and s.expires_at > ^now
    )
  end

  defp active_stories_for(profile_id) do
    now = DateTime.utc_now()

    Repo.all(
      from s in Story,
        where: s.profile_id == ^profile_id and s.active == true and s.expires_at > ^now,
        order_by: [asc: s.id]
    )
  end

  defp seen_set(_viewer_id, []), do: MapSet.new()

  defp seen_set(viewer_id, story_ids) do
    Repo.all(
      from v in View,
        where: v.profile_id == ^viewer_id and v.story_id in ^story_ids,
        select: v.story_id
    )
    |> MapSet.new()
  end

  ## Mark seen

  @spec mark_seen(Profile.t(), integer()) :: {:ok, Story.t()} | {:error, atom()}
  def mark_seen(%Profile{id: viewer_id}, story_id) when is_integer(story_id) do
    case Repo.get(Story, story_id) do
      nil ->
        {:error, :not_found}

      %Story{active: false} ->
        {:error, :inactive}

      %Story{profile_id: ^viewer_id} = s ->
        {:ok, s}

      %Story{profile_id: pid} = s ->
        if follower?(viewer_id, pid) do
          # A first view of a remote story is reported to its author.
          with {:ok, true} <- do_mark_seen(s, viewer_id),
               %Profile{domain: nil} = viewer <- Repo.get(Profile, viewer_id) do
            Outbound.viewed(s, viewer)
          end

          {:ok, s}
        else
          {:error, :forbidden}
        end
    end
  end

  defp follower?(viewer_id, target_id) do
    Repo.exists?(
      from f in Follower,
        where:
          f.profile_id == ^target_id and f.following_id == ^viewer_id and
            not is_nil(f.accepted_at)
    )
  end

  defp do_mark_seen(%Story{id: story_id}, viewer_id) do
    Repo.transaction(fn ->
      result =
        %{story_id: story_id, profile_id: viewer_id}
        |> View.changeset()
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:story_id, :profile_id])

      case result do
        {:ok, %View{id: id}} when not is_nil(id) ->
          {1, _} =
            Repo.update_all(
              from(s in Story, where: s.id == ^story_id),
              inc: [view_count: 1]
            )

          true

        _ ->
          false
      end
    end)
  end

  ## Delete (author force-expire)

  @spec delete(Profile.t(), integer()) :: :ok | {:error, atom()}
  def delete(%Profile{id: viewer_id}, story_id) when is_integer(story_id) do
    case Repo.get(Story, story_id) do
      nil ->
        {:error, :not_found}

      %Story{profile_id: pid} when pid != viewer_id ->
        {:error, :forbidden}

      story ->
        story |> Ecto.Changeset.change(active: false) |> Repo.update!() |> Outbound.removed()
        :ok
    end
  end

  ## Mention autocomplete (v1.2 publishNext composer)

  @doc """
  Suggest up to 10 followers of `viewer` whose username starts with `prefix`.
  Used by the v1.2 story composer to gate `@mention` overlays — Pixelfed
  only lets you mention people who follow you.
  """
  @spec mention_autocomplete(Profile.t(), String.t()) :: [Profile.t()]
  def mention_autocomplete(%Profile{id: viewer_id}, prefix) when is_binary(prefix) do
    cleaned = prefix |> String.trim_leading("@") |> String.trim()

    if cleaned == "" do
      []
    else
      pattern = escape_like(cleaned) <> "%"

      Repo.all(
        from p in Profile,
          join: f in Follower,
          on: f.profile_id == p.id and f.following_id == ^viewer_id,
          where: ilike(p.username, ^pattern) and not is_nil(f.accepted_at),
          order_by: [asc: p.username],
          limit: 10
      )
    end
  end

  defp escape_like(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  ## Combined add+publish with overlays (v1.2 publishNext)

  @doc """
  Newer "publish-in-one-shot" flow: upload, validate overlays, and flip
  active in a single call. Pixelfed-style overlays are stored opaque on
  the story for the client to render.

  Mentions in `overlays` are validated as following the author (matches
  Pixelfed's gate). Returns `{:error, {:invalid_overlay, index, reason}}`
  on the first overlay that fails validation.
  """
  @spec publish_next(Profile.t(), map(), list()) ::
          {:ok, Story.t()}
          | {:error, atom()}
          | {:error, {:invalid_overlay, non_neg_integer(), atom()}}
  def publish_next(%Profile{} = author, upload, overlays) when is_list(overlays) do
    cond do
      not enabled?() ->
        {:error, :disabled}

      length(overlays) > 4 ->
        {:error, :too_many_overlays}

      active_today_count(author.id) >= @max_per_day ->
        {:error, :limit_reached}

      true ->
        with {:ok, validated} <- validate_overlays(author, overlays),
             {:ok, story} <- do_add(author, upload, %{}) do
          story
          |> Ecto.Changeset.change(
            active: true,
            overlays: validated,
            bearcap_token: mint_bearcap(),
            expires_at: DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)
          )
          |> Repo.update()
          |> tap(&fan_out_published/1)
        end
    end
  end

  defp validate_overlays(author, overlays) do
    overlays
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {ov, idx}, {:ok, acc} ->
      case validate_overlay(author, ov) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_overlay, idx, reason}}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  @overlay_string_keys ~w(content type fontFamily backgroundColor color)
  @overlay_numeric_keys ~w(absoluteScale absoluteX absoluteY fontSize rotation scale x y)

  defp validate_overlay(author, %{} = ov) do
    type = overlay_field(ov, :type)
    content = overlay_field(ov, :content)

    with :ok <- check_overlay_type(type),
         {:ok, normalized_content} <- check_overlay_content(author, type, content) do
      {:ok, ov |> sanitize_overlay() |> Map.put("content", normalized_content)}
    end
  end

  defp validate_overlay(_, _), do: {:error, :not_a_map}

  # Overlays may be string- or atom-keyed; the string key wins.
  defp overlay_field(ov, key), do: Map.get(ov, Atom.to_string(key)) || Map.get(ov, key)

  defp sanitize_overlay(ov) do
    ov
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.take(@overlay_string_keys ++ @overlay_numeric_keys)
  end

  defp check_overlay_type(t) when t in ["text", "mention", "hashtag", "url"], do: :ok
  defp check_overlay_type(_), do: {:error, :bad_type}

  defp check_overlay_content(_, "text", c) when is_binary(c) and byte_size(c) > 0 do
    if Regex.match?(~r/^[\p{L}\p{N}\s\p{P}\p{S}]*$/u, c),
      do: {:ok, c},
      else: {:error, :bad_text}
  end

  defp check_overlay_content(_, "hashtag", c) when is_binary(c) do
    if Regex.match?(~r/^#[A-Za-z0-9_]{1,29}$/, c),
      do: {:ok, c},
      else: {:error, :bad_hashtag}
  end

  defp check_overlay_content(_, "url", c) when is_binary(c) do
    case URI.parse(c) do
      %URI{scheme: "https", host: h} when is_binary(h) and h != "" -> {:ok, c}
      _ -> {:error, :bad_url}
    end
  end

  defp check_overlay_content(%Profile{} = author, "mention", c) when is_binary(c) do
    username = c |> String.trim_leading("@") |> String.trim()

    cond do
      username == "" ->
        {:error, :empty_mention}

      mention_allowed?(author, username) ->
        {:ok, username}

      true ->
        {:error, :unknown_mention}
    end
  end

  defp check_overlay_content(_, _, _), do: {:error, :bad_content}

  defp mention_allowed?(%Profile{id: viewer_id}, username) do
    Repo.exists?(
      from p in Profile,
        join: f in Follower,
        on: f.profile_id == p.id and f.following_id == ^viewer_id,
        where:
          fragment("lower(?)", p.username) == ^String.downcase(username) and
            not is_nil(f.accepted_at)
    )
  end

  ## Viewers (author-only — list who has seen one of my own active stories)

  @doc """
  Page through viewers of one of the caller's own active stories.

  `opts[:limit]` (default 20, capped at 80) and `opts[:max_id]` for cursor
  pagination — `max_id` is a `story_views.id` and the page strictly precedes
  it (newest-first).
  """
  @spec viewers(Profile.t(), integer(), keyword()) ::
          {:ok, %{viewers: [map()], next_max_id: integer() | nil}}
          | {:error, atom()}
  def viewers(%Profile{id: viewer_id}, story_id, opts \\ [])
      when is_integer(story_id) do
    limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(80)
    max_id = Keyword.get(opts, :max_id)

    case Repo.get(Story, story_id) do
      nil ->
        {:error, :not_found}

      %Story{profile_id: pid} when pid != viewer_id ->
        {:error, :forbidden}

      %Story{active: false} ->
        {:error, :inactive}

      %Story{} ->
        rows = viewer_rows(story_id, limit, max_id)

        next =
          case rows do
            [] -> nil
            list -> if length(list) < limit, do: nil, else: List.last(list).id
          end

        {:ok,
         %{
           viewers: Enum.map(rows, &render_viewer(&1, viewer_id)),
           next_max_id: next
         }}
    end
  end

  defp viewer_rows(story_id, limit, max_id) do
    base =
      from v in View,
        where: v.story_id == ^story_id,
        order_by: [desc: v.id],
        limit: ^limit,
        preload: [:profile]

    query =
      case max_id do
        n when is_integer(n) -> from v in base, where: v.id < ^n
        _ -> base
      end

    Repo.all(query)
  end

  defp render_viewer(%View{id: vid, profile: %Profile{} = p, inserted_at: at}, viewer_id) do
    Map.merge(render_user(p, viewer_id), %{
      "view_id" => Integer.to_string(vid),
      "seen_at" => DateTime.to_iso8601(at)
    })
  end

  ## Comment / react (→ story:reply / story:reaction DM)

  @max_message 500
  @max_reactions 5

  @doc """
  Reply to a story: a `story:reply` `:direct` status from `sender` to the
  author, filed into their DM conversation and, for a remote story, sent to
  its author as `Story:Reply` (upstream StoryApiV1Controller::comment).
  """
  @spec comment(Profile.t(), integer(), String.t()) ::
          {:ok, Statuses.Status.t()} | {:error, atom()}
  def comment(%Profile{} = sender, story_id, text)
      when is_integer(story_id) and is_binary(text) and text != "" do
    case Repo.get(Story, story_id) do
      nil -> {:error, :not_found}
      %Story{can_reply: false} -> {:error, :replies_disabled}
      story -> send_message(story, sender, :reply, text)
    end
  end

  def comment(_, _, _), do: {:error, :empty_comment}

  @doc """
  React to a story (an emoji, as free text): a `story:reaction` DM, and
  `Story:Reaction` for a remote story. At most #{@max_reactions} per story
  each (upstream StoryComposeController::react).
  """
  @spec react(Profile.t(), integer(), String.t()) ::
          {:ok, Statuses.Status.t()} | {:error, atom()}
  def react(%Profile{} = sender, story_id, text)
      when is_integer(story_id) and is_binary(text) and text != "" do
    case Repo.get(Story, story_id) do
      nil ->
        {:error, :not_found}

      %Story{can_react: false} ->
        {:error, :reactions_disabled}

      story ->
        if reaction_count(story.id, sender.id) >= @max_reactions,
          do: {:error, :limit_reached},
          else: send_message(story, sender, :reaction, text)
    end
  end

  def react(_, _, _), do: {:error, :empty_reaction}

  defp reaction_count(story_id, sender_id) do
    Repo.aggregate(
      from(s in Status,
        where:
          s.story_id == ^story_id and s.profile_id == ^sender_id and s.type == "story:reaction"
      ),
      :count
    )
  end

  # Only a live story, from someone who follows the author, with no block
  # either way.
  defp send_message(%Story{} = story, %Profile{domain: nil} = sender, kind, text) do
    if commentable?(story, sender) do
      story = Repo.preload(story, :profile)
      id = Angler.Snowflake.next()
      uri = AnglerWeb.Endpoint.url() <> "/p/" <> sender.username <> "/" <> Integer.to_string(id)

      with {:ok, status} <-
             record_message(story, sender, kind, String.slice(text, 0, @max_message),
               id: id,
               local: true,
               uri: uri,
               url: uri
             ) do
        Outbound.interacted(story, status, kind)
        {:ok, status}
      end
    else
      {:error, :not_found}
    end
  end

  defp send_message(_, _, _, _), do: {:error, :not_found}

  @doc """
  Store a story reply or reaction from `sender` as a `:direct` status to the
  story's author, mentioning them, and file it into their DM conversation
  (upstream DirectMessageService::storeStoryMessage). `attrs` carries the
  status's own fields: `:local`, `:uri`, `:url`, and optionally `:id`.
  Idempotent on the uri.
  """
  @spec record_message(Story.t(), Profile.t(), :reaction | :reply, String.t(), keyword()) ::
          {:ok, Status.t()} | {:error, term()}
  def record_message(%Story{} = story, %Profile{} = sender, kind, text, attrs) do
    {id, attrs} = Keyword.pop(attrs, :id)
    html = text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    attrs =
      Map.merge(
        %{
          profile_id: sender.id,
          caption: text,
          rendered: "<p>" <> html <> "</p>",
          visibility: :direct,
          scope: "direct",
          type: if(kind == :reply, do: "story:reply", else: "story:reaction"),
          in_reply_to_profile_id: story.profile_id,
          story_id: story.id
        },
        Map.new(attrs)
      )

    with {:ok, %Status{} = status} <- insert_message(%Status{id: id}, attrs) do
      %{status_id: status.id, profile_id: story.profile_id}
      |> Mention.changeset()
      |> Repo.insert!(on_conflict: :nothing, conflict_target: [:status_id, :profile_id])

      :ok = Angler.Conversations.record_story_message(status)
      {:ok, status}
    end
  end

  # The uri index is partial, so a duplicate surfaces as a constraint error
  # rather than through ON CONFLICT (as `Statuses.create_remote/1`).
  defp insert_message(status, attrs) do
    status |> Status.changeset(attrs) |> Repo.insert()
  rescue
    Ecto.ConstraintError -> {:error, :exists}
  end

  defp commentable?(%Story{profile_id: author_id} = story, %Profile{id: sender_id}) do
    story.active == true and
      DateTime.compare(story.expires_at, DateTime.utc_now()) == :gt and
      match?(%{accepted_at: %DateTime{}}, Angler.Follows.get_follower(author_id, sender_id)) and
      not Angler.Profiles.BlocksMutes.blocked?(author_id, sender_id) and
      not Angler.Profiles.BlocksMutes.blocked?(sender_id, author_id)
  end

  ## Expiry (called by the cron worker)

  @doc """
  Flip every published story past its `expires_at` to inactive and send
  the `Delete` of each local one; mirrored remote stories are dropped with
  their media (upstream StoryExpire). Returns the count.
  """
  @spec expire_due() :: non_neg_integer()
  def expire_due do
    now = DateTime.utc_now()

    {n, expired} =
      from(s in Story, where: s.active == true and s.expires_at <= ^now, select: s)
      |> Repo.update_all(set: [active: false, updated_at: now])

    {local, remote} = Enum.split_with(expired, & &1.local)
    Enum.each(local, &Outbound.removed/1)
    purge_remote(remote)

    n
  end

  @doc "Delete mirrored remote stories and their stored media."
  @spec purge_remote([Story.t()]) :: :ok
  def purge_remote(stories) when is_list(stories) do
    stories = Enum.reject(stories, & &1.local)
    ids = Enum.map(stories, & &1.id)
    {_, _} = Repo.delete_all(from s in Story, where: s.id in ^ids)
    Enum.each(stories, &RemoteMedia.delete(&1.path))
  end

  ## Rendering helpers (used by both this module and the controller)

  def render_user(%Profile{} = p, viewer_id) do
    %{
      "id" => Integer.to_string(p.id),
      "username" => p.username,
      "username_acct" => acct(p),
      "avatar" => p.avatar_path || "",
      "local" => is_nil(p.domain),
      "is_author" => p.id == viewer_id
    }
  end

  def render_node(%Story{} = s, viewer_id, seen \\ nil) do
    seen =
      case seen do
        nil ->
          Repo.exists?(
            from v in View,
              where: v.story_id == ^s.id and v.profile_id == ^viewer_id
          )

        bool ->
          bool
      end

    %{
      "id" => Integer.to_string(s.id),
      "pid" => Integer.to_string(s.profile_id),
      "type" => s.type,
      "src" => media_url(s),
      "duration" => div(s.duration_ms, 1000),
      "seen" => seen,
      "can_reply" => s.can_reply,
      "can_react" => s.can_react,
      "view_count" => s.view_count,
      "overlays" => s.overlays || [],
      "created_at" => DateTime.to_iso8601(s.inserted_at),
      "expires_at" => DateTime.to_iso8601(s.expires_at)
    }
  end

  @doc """
  A story's media URL. Remote stories mirrored before their media was
  downloaded (`Angler.Stories.RemoteMedia`) hotlink it, so their `path` is
  already the URL.
  """
  @spec media_url(Story.t()) :: String.t()
  def media_url(%Story{local: false, path: url}) when is_binary(url) do
    if RemoteMedia.hotlinked?(url), do: url, else: stored_url(url)
  end

  def media_url(%Story{path: path}), do: stored_url(path)

  # Stories don't share the Asset schema; the storage backend's `url/2`
  # signature wants an Asset, so we synthesize a minimal one.
  defp stored_url(path),
    do: Storage.backend().url(%Angler.Media.Asset{path_original: path}, :original) || path

  @doc """
  The v1.1 DM `{type, meta}` of a story reply or reaction status, or nil for
  any other message (upstream DmMessage story:comment / story:react).
  """
  @spec message_meta(Statuses.Status.t()) :: {String.t(), map()} | nil
  def message_meta(%Statuses.Status{type: type, story_id: sid} = status)
      when type in ["story:reply", "story:reaction"] and is_integer(sid) do
    with %Story{} = story <- Repo.get(Story, sid) |> Repo.preload(:profile),
         %Profile{} = sender <- Repo.get(Profile, status.profile_id) do
      {dm_type, key} =
        if type == "story:reply",
          do: {"story:comment", "caption"},
          else: {"story:react", "reaction"}

      {dm_type,
       %{
         "story_id" => Integer.to_string(story.id),
         "story_username" => story.profile.username,
         "story_actor_username" => sender.username,
         "story_media_url" => media_url(story),
         key => status.caption
       }}
    else
      _ -> nil
    end
  end

  def message_meta(_), do: nil

  ## Internals

  defp ext_for("image/jpeg"), do: "jpg"
  defp ext_for("image/png"), do: "png"
  defp ext_for("video/mp4"), do: "mp4"
  defp ext_for(_), do: "bin"

  defp sha256(path) do
    state =
      File.stream!(path, 65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))

    :crypto.hash_final(state)
  end

  defp parse_duration_ms(v, default \\ 3_000)

  defp parse_duration_ms(n, _default) when is_integer(n) and n > 0,
    do: clamp(n * 1_000, 1_000, 30_000)

  defp parse_duration_ms(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> clamp(n * 1_000, 1_000, 30_000)
      _ -> default
    end
  end

  defp parse_duration_ms(_, default), do: default

  defp clamp(n, lo, _hi) when n < lo, do: lo
  defp clamp(n, _lo, hi) when n > hi, do: hi
  defp clamp(n, _, _), do: n

  defp truthy?(true, _), do: true
  defp truthy?("true", _), do: true
  defp truthy?("1", _), do: true
  defp truthy?(false, _), do: false
  defp truthy?("false", _), do: false
  defp truthy?("0", _), do: false
  defp truthy?(_, default), do: default

  defp acct(%Profile{domain: nil, username: u}), do: u
  defp acct(%Profile{domain: d, username: u}), do: "#{u}@#{d}"
end
