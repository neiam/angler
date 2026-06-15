defmodule Angler.Import.Instagram do
  @moduledoc """
  Import an Instagram data export ("Download Your Information", **JSON** format)
  into a local profile as backdated, silent posts.

  ## What it does

    * Locates the feed-posts file (`posts_1.json`, …) inside an extracted
      export — handling both the legacy `content/` layout and the newer
      `your_instagram_activity/` layout.
    * Uploads each post's media through `Angler.Media.upload/3` (re-using the
      existing sniff/process/dedup pipeline).
    * Creates one `Angler.Statuses` post per Instagram post, **backdated** to the
      original `creation_timestamp` via `Angler.Snowflake.from_timestamp/2` so it
      sorts into the correct chronological position, with `inserted_at` set to
      the same instant.

  ## What it deliberately does *not* do

    * It does **not** federate or fan posts into home timelines — `create_local`
      is called directly with `broadcast: false`, and no `FeedInsert` /
      `StatusDeliver` jobs are enqueued. Imported posts appear in the author's
      profile grid only (silent backfill).
    * It only handles **feed posts**. Stories, reels, IGTV and archived posts
      live in separate files and are out of scope.

  ## Idempotency

  Each post's snowflake id is derived deterministically from its timestamp (and
  a per-millisecond sequence for same-second collisions), so re-running an import
  over the same export skips posts that already exist and re-uses media via the
  `(sha256, profile_id)` dedup. Re-running is safe.

  Media uploads enqueue async `ImageProcess` jobs as usual; run this with the
  app (and the `:media` Oban queue) started so attachments finish processing.
  """

  require Logger
  import Ecto.Query, only: [from: 2]

  alias Angler.{Media, Repo, Snowflake, Statuses}
  alias Angler.Profiles.Profile
  alias Angler.Statuses.Status

  @type summary :: %{
          posts: non_neg_integer(),
          imported: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          errors: [String.t()]
        }

  @doc """
  Extract a `.zip` export to a temp directory and import it. The temp directory
  is removed afterwards. See `import_dir/3` for options.
  """
  @spec import_zip(Profile.t(), Path.t(), keyword()) ::
          {:ok, summary()} | {:error, term()}
  def import_zip(%Profile{} = profile, zip_path, opts \\ []) do
    with {:ok, dir} <- extract_zip(zip_path) do
      try do
        import_dir(profile, dir, opts)
      after
        File.rm_rf(dir)
      end
    end
  end

  @doc """
  Import from an already-extracted export directory (`root_dir` is the export
  root — the directory that contains `media/` and the posts JSON).

  ## Options

    * `:visibility` — visibility for created posts (default `"public"`).
    * `:language` — default language code for posts (default `"en"`).
    * `:dry_run` — when `true`, parse and report counts without uploading media
      or creating posts (default `false`).
    * `:on_progress` — optional `fn idx, total -> :ok end` called per post.
  """
  @spec import_dir(Profile.t(), Path.t(), keyword()) ::
          {:ok, summary()} | {:error, term()}
  def import_dir(profile, root_dir, opts \\ [])

  def import_dir(%Profile{domain: nil} = profile, root_dir, opts) do
    case find_posts_files(root_dir) do
      [] ->
        {:error, :no_posts_file}

      files ->
        posts = files |> Enum.flat_map(&decode_posts/1)
        {:ok, run(profile, root_dir, posts, opts)}
    end
  end

  def import_dir(%Profile{}, _root_dir, _opts), do: {:error, :not_local_profile}

  ## ---- internals -------------------------------------------------------

  defp run(profile, root_dir, posts, opts) do
    total = length(posts)
    on_progress = Keyword.get(opts, :on_progress)
    dry_run? = Keyword.get(opts, :dry_run, false)

    init = %{posts: total, imported: 0, skipped: 0, failed: 0, errors: [], seen_ms: %{}}

    summary =
      posts
      |> Enum.with_index(1)
      |> Enum.reduce(init, fn {post, idx}, acc ->
        if is_function(on_progress, 2), do: on_progress.(idx, total)
        import_one(profile, root_dir, post, opts, dry_run?, acc)
      end)

    summary
    |> Map.delete(:seen_ms)
    |> Map.update!(:errors, &Enum.reverse/1)
  end

  defp import_one(profile, root_dir, post, opts, dry_run?, acc) do
    with {:ok, ms} <- post_timestamp_ms(post) do
      {seq, seen_ms} = next_seq(acc.seen_ms, ms)
      id = Snowflake.from_timestamp(ms, seq)
      acc = %{acc | seen_ms: seen_ms}

      cond do
        status_exists?(id) ->
          %{acc | skipped: acc.skipped + 1}

        dry_run? ->
          %{acc | imported: acc.imported + 1}

        true ->
          do_import(profile, root_dir, post, id, ms, opts, acc)
      end
    else
      :error -> fail(acc, "post missing creation_timestamp")
    end
  end

  defp do_import(profile, root_dir, post, id, ms, opts, acc) do
    media = Map.get(post, "media", []) |> List.wrap()
    {asset_ids, errors} = upload_media(profile, root_dir, media)

    cond do
      asset_ids == [] ->
        fail(acc, "no usable media for post @ #{ms}; #{Enum.join(errors, "; ")}")

      true ->
        attrs = %{
          "status" => caption_for(post, media),
          "media_ids" => asset_ids,
          "visibility" => Keyword.get(opts, :visibility, "public"),
          "language" => Keyword.get(opts, :language, "en")
        }

        # :utc_datetime_usec columns require microsecond precision.
        created_at = DateTime.from_unix!(ms * 1000, :microsecond)
        post_opts = [id: id, created_at: created_at, broadcast: false]

        case Statuses.create_local(profile, attrs, post_opts) do
          {:ok, _status} ->
            %{acc | imported: acc.imported + 1, errors: errors ++ acc.errors}

          {:error, reason} ->
            fail(acc, "create_local failed @ #{ms}: #{inspect(reason)}")
        end
    end
  end

  # Upload each media file; returns {usable_asset_ids, error_messages}.
  defp upload_media(profile, root_dir, media) do
    media
    |> Enum.reduce({[], []}, fn item, {ids, errs} ->
      uri = item["uri"]

      case resolve_media_path(root_dir, uri) do
        {:ok, path} ->
          upload = %Plug.Upload{
            path: path,
            filename: Path.basename(path),
            content_type: content_type_for(path)
          }

          case Media.upload(profile, upload, %{"description" => alt_for(item)}) do
            {:ok, asset} -> {[asset.id | ids], errs}
            {:error, reason} -> {ids, ["upload #{uri}: #{inspect(reason)}" | errs]}
          end

        :error ->
          {ids, ["missing media file: #{inspect(uri)}" | errs]}
      end
    end)
    |> then(fn {ids, errs} -> {Enum.reverse(ids), Enum.reverse(errs)} end)
  end

  defp fail(acc, message) do
    Logger.warning("[instagram-import] #{message}")
    %{acc | failed: acc.failed + 1, errors: [message | acc.errors]}
  end

  ## ---- post parsing -----------------------------------------------------

  # Post-level caption; for single-media posts the caption often lives on the
  # lone media entry instead. Instagram mojibake-encodes non-ASCII text.
  defp caption_for(post, media) do
    raw =
      case String.trim(to_string(post["title"] || "")) do
        "" -> single_media_title(media)
        title -> title
      end

    fix_encoding(raw || "")
  end

  defp single_media_title([%{"title" => t}]), do: t
  defp single_media_title(_), do: nil

  defp alt_for(%{"title" => t}) when is_binary(t) and t != "", do: fix_encoding(t)
  defp alt_for(_), do: nil

  # Instagram writes UTF-8 bytes that were decoded as Latin-1 — the classic
  # "Ã©" mojibake. If every codepoint fits in a byte, re-interpret the bytes as
  # UTF-8 to recover the original text; otherwise the string is already correct.
  defp fix_encoding(str) when is_binary(str) do
    cps = String.to_charlist(str)

    if cps != [] and Enum.all?(cps, &(&1 <= 255)) do
      bytes = :binary.list_to_bin(cps)

      case :unicode.characters_to_binary(bytes, :utf8) do
        fixed when is_binary(fixed) -> fixed
        _ -> str
      end
    else
      str
    end
  end

  defp post_timestamp_ms(post) do
    first_media = post |> Map.get("media", []) |> List.wrap() |> List.first() || %{}
    ts = post["creation_timestamp"] || first_media["creation_timestamp"]

    case ts do
      n when is_integer(n) and n > 0 -> {:ok, n * 1000}
      _ -> :error
    end
  end

  # Per-millisecond sequence so multiple posts in the same second mint distinct
  # snowflakes. Deterministic given input order → re-runs reproduce the same ids.
  defp next_seq(seen_ms, ms) do
    seq = Map.get(seen_ms, ms, 0)
    {seq, Map.put(seen_ms, ms, seq + 1)}
  end

  defp status_exists?(id) do
    Repo.exists?(from(s in Status, where: s.id == ^id))
  end

  ## ---- file discovery ---------------------------------------------------

  defp find_posts_files(root_dir) do
    [
      Path.join([root_dir, "**", "posts_[0-9]*.json"]),
      Path.join(root_dir, "posts_[0-9]*.json")
    ]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp decode_posts(file) do
    with {:ok, body} <- File.read(file),
         {:ok, decoded} <- Jason.decode(body) do
      posts_from(decoded)
    else
      _ ->
        Logger.warning("[instagram-import] could not decode #{file}")
        []
    end
  end

  # The feed-posts file is a bare array. Be lenient: if it's an object, take the
  # first list-valued field (some export variants wrap the array under a key).
  defp posts_from(list) when is_list(list), do: list

  defp posts_from(map) when is_map(map) do
    map
    |> Map.values()
    |> Enum.find(&is_list/1)
    |> List.wrap()
  end

  defp posts_from(_), do: []

  # Media `uri`s are relative to the export root. Fall back to a basename search
  # for exports whose folder layout differs from the recorded path.
  defp resolve_media_path(_root_dir, uri) when not is_binary(uri), do: :error

  defp resolve_media_path(root_dir, uri) do
    direct = Path.join(root_dir, uri)

    cond do
      File.regular?(direct) ->
        {:ok, direct}

      true ->
        case Path.wildcard(Path.join([root_dir, "**", Path.basename(uri)])) do
          [hit | _] -> {:ok, hit}
          [] -> :error
        end
    end
  end

  defp content_type_for(path) do
    case path |> Path.extname() |> String.downcase() do
      ext when ext in [".jpg", ".jpeg"] -> "image/jpeg"
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      ".mp4" -> "video/mp4"
      ".webm" -> "video/webm"
      ".mov" -> "video/quicktime"
      # Hand anything else to Media.upload, which sniffs magic bytes and
      # rejects unsupported types (e.g. HEIC) — we then log and skip it.
      _ -> "application/octet-stream"
    end
  end

  defp extract_zip(zip_path) do
    if File.regular?(zip_path) do
      dir = Path.join(System.tmp_dir!(), "angler-ig-import-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      case :zip.extract(String.to_charlist(zip_path), [{:cwd, String.to_charlist(dir)}]) do
        {:ok, _files} ->
          {:ok, dir}

        {:error, reason} ->
          File.rm_rf(dir)
          {:error, {:bad_zip, reason}}
      end
    else
      {:error, :no_zip}
    end
  end
end
