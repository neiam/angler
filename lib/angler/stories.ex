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

  Comments on stories become `:direct` statuses to the author with a
  reference embedded — see `comment/3`.
  """

  import Ecto.Query, warn: false

  alias Angler.Follows.Follower
  alias Angler.Media.Storage
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses
  alias Angler.Stories.{Story, View}

  @max_per_day 30
  @ttl_seconds 24 * 60 * 60

  @image_mimes ~w(image/jpeg image/png)
  @video_mimes ~w(video/mp4)

  @doc "Whether the operator has enabled the stories feature."
  def enabled?, do: Application.get_env(:angler, :stories_enabled, false) == true

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
          expires_at: DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)
        )
        |> Repo.update()
    end
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
          do_mark_seen(s, viewer_id)
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
          Repo.update_all(
            from(s in Story, where: s.id == ^story_id),
            inc: [view_count: 1]
          )

        _ ->
          :ok
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
        story |> Ecto.Changeset.change(active: false) |> Repo.update!()
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
            expires_at: DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)
          )
          |> Repo.update()
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
    type = Map.get(ov, "type") || Map.get(ov, :type)
    content = Map.get(ov, "content") || Map.get(ov, :content)

    with :ok <- check_overlay_type(type),
         {:ok, normalized_content} <- check_overlay_content(author, type, content) do
      {:ok, ov |> sanitize_overlay() |> Map.put("content", normalized_content)}
    end
  end

  defp validate_overlay(_, _), do: {:error, :not_a_map}

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

        rows = Repo.all(query)

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

  defp render_viewer(%View{id: vid, profile: %Profile{} = p, inserted_at: at}, viewer_id) do
    Map.merge(render_user(p, viewer_id), %{
      "view_id" => Integer.to_string(vid),
      "seen_at" => DateTime.to_iso8601(at)
    })
  end

  ## Comment (story reply → :direct status)

  @spec comment(Profile.t(), integer(), String.t()) ::
          {:ok, Statuses.Status.t()} | {:error, atom()}
  def comment(%Profile{} = sender, story_id, text)
      when is_integer(story_id) and is_binary(text) and text != "" do
    case Repo.get(Story, story_id) do
      nil ->
        {:error, :not_found}

      %Story{can_reply: false} ->
        {:error, :replies_disabled}

      %Story{profile_id: author_id} ->
        author = Repo.get!(Profile, author_id)

        Statuses.create_local(sender, %{
          "status" => "@" <> author.username <> " " <> text,
          "visibility" => "direct"
        })
    end
  end

  def comment(_, _, _), do: {:error, :empty_comment}

  ## Expiry (called by the cron worker)

  @spec expire_due() :: non_neg_integer()
  def expire_due do
    now = DateTime.utc_now()

    {n, _} =
      from(s in Story, where: s.active == true and s.expires_at <= ^now)
      |> Repo.update_all(set: [active: false, updated_at: now])

    n
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
      "src" => Storage.backend().url(struct_for_storage(s), :original) || s.path,
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

  # Stories don't share the Asset schema; the storage backend's `url/2`
  # signature wants an Asset, so we synthesize a minimal one.
  defp struct_for_storage(%Story{} = s) do
    %Angler.Media.Asset{path_original: s.path}
  end

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
