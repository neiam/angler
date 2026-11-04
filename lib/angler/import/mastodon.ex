defmodule Angler.Import.Mastodon do
  @moduledoc """
  Import a Mastodon (or Pixelfed) account export into a local profile as
  backdated, silent posts — the ActivityPub counterpart to
  `Angler.Import.Instagram`.

  Both Mastodon and Pixelfed exports ship an `outbox.json` (an AS2
  `OrderedCollection` of `Create` activities wrapping `Note` objects) and a
  `media_attachments/` directory. We walk the outbox, recover each note's text
  and timestamp, resolve any bundled attachments by filename, and create one
  backdated local post per note via `Statuses.create_local/3` with
  `broadcast: false` (no federation, no home-feed fan-out — see
  `Angler.Import.Instagram` for the rationale).

  Idempotent: each post's snowflake id is derived from its `published` time, so
  re-running skips notes that already exist and re-uses media via the
  `(sha256, profile_id)` dedup.
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

  @spec import_zip(Profile.t(), Path.t(), keyword()) :: {:ok, summary()} | {:error, term()}
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
  Import from an extracted export directory containing `outbox.json`.

  Options: `:visibility` (default keeps each note's own audience-derived scope,
  falling back to `"public"`), `:language` (default `"en"`), `:dry_run`,
  `:on_progress`.
  """
  @spec import_dir(Profile.t(), Path.t(), keyword()) :: {:ok, summary()} | {:error, term()}
  def import_dir(profile, root_dir, opts \\ [])

  def import_dir(%Profile{domain: nil} = profile, root_dir, opts) do
    case find_outbox(root_dir) do
      nil -> {:error, :no_outbox_file}
      file -> {:ok, run(profile, root_dir, decode_outbox(file), opts)}
    end
  end

  def import_dir(%Profile{}, _root_dir, _opts), do: {:error, :not_local_profile}

  ## ---- internals -------------------------------------------------------

  defp run(profile, root_dir, notes, opts) do
    total = length(notes)
    on_progress = Keyword.get(opts, :on_progress)
    dry_run? = Keyword.get(opts, :dry_run, false)

    init = %{posts: total, imported: 0, skipped: 0, failed: 0, errors: [], seen_ms: %{}}

    notes
    |> Enum.with_index(1)
    |> Enum.reduce(init, fn {note, idx}, acc ->
      if is_function(on_progress, 2), do: on_progress.(idx, total)
      import_one(profile, root_dir, note, opts, dry_run?, acc)
    end)
    |> Map.delete(:seen_ms)
    |> Map.update!(:errors, &Enum.reverse/1)
  end

  defp import_one(profile, root_dir, note, opts, dry_run?, acc) do
    case published_ms(note) do
      {:ok, ms} ->
        {seq, seen_ms} = next_seq(acc.seen_ms, ms)
        id = Snowflake.from_timestamp(ms, seq)
        acc = %{acc | seen_ms: seen_ms}

        cond do
          status_exists?(id) -> %{acc | skipped: acc.skipped + 1}
          dry_run? -> %{acc | imported: acc.imported + 1}
          true -> do_import(profile, root_dir, note, id, ms, opts, acc)
        end

      :error ->
        fail(acc, "note missing published timestamp")
    end
  end

  defp do_import(profile, root_dir, note, id, ms, opts, acc) do
    {asset_ids, errors} = upload_media(profile, root_dir, attachments(note))
    caption = caption_for(note)

    if caption == "" and asset_ids == [] do
      fail(%{acc | errors: errors ++ acc.errors}, "empty note @ #{ms}")
    else
      attrs = %{
        "status" => caption,
        "media_ids" => asset_ids,
        "visibility" => visibility_for(note, opts),
        "language" => Keyword.get(opts, :language, "en"),
        "sensitive" => note["sensitive"] == true
      }

      created_at = DateTime.from_unix!(ms * 1000, :microsecond)
      post_opts = [id: id, created_at: created_at, broadcast: false]

      case Statuses.create_local(profile, attrs, post_opts) do
        {:ok, _status} -> %{acc | imported: acc.imported + 1, errors: errors ++ acc.errors}
        {:error, reason} -> fail(acc, "create_local failed @ #{ms}: #{inspect(reason)}")
      end
    end
  end

  defp upload_media(profile, root_dir, attachments) do
    attachments
    |> Enum.reduce({[], []}, fn att, {ids, errs} ->
      url = attachment_url(att)

      case resolve_media_path(root_dir, url) do
        {:ok, path} ->
          upload = %Plug.Upload{
            path: path,
            filename: Path.basename(path),
            content_type: att["mediaType"] || content_type_for(path)
          }

          case Media.upload(profile, upload, %{"description" => att["name"]}) do
            {:ok, asset} -> {[asset.id | ids], errs}
            {:error, reason} -> {ids, ["upload #{inspect(url)}: #{inspect(reason)}" | errs]}
          end

        :error ->
          # Text posts have no attachments; only note a miss when one was named.
          if is_binary(url),
            do: {ids, ["missing media: #{Path.basename(url)}" | errs]},
            else: {ids, errs}
      end
    end)
    |> then(fn {ids, errs} -> {Enum.reverse(ids), Enum.reverse(errs)} end)
  end

  defp fail(acc, message) do
    Logger.warning("[mastodon-import] #{message}")
    %{acc | failed: acc.failed + 1, errors: [message | acc.errors]}
  end

  ## ---- note parsing -----------------------------------------------------

  # Each orderedItems entry is a `Create` wrapping a `Note`, or (rarely) a bare
  # `Note`. Reblogs (`Announce`) and other verbs are skipped.
  defp object(%{"type" => "Create", "object" => obj}) when is_map(obj), do: obj
  defp object(%{"type" => "Note"} = note), do: note
  defp object(_), do: nil

  defp caption_for(note) do
    note
    |> Map.get("content", "")
    |> to_string()
    |> strip_html()
    |> String.trim()
  end

  # Mastodon/Pixelfed content is HTML. Recover plain text: paragraph/line breaks
  # become newlines, remaining tags are dropped, then entities are unescaped.
  # The new post re-extracts #hashtags and @mentions from this text.
  defp strip_html(html) do
    html
    |> String.replace(~r{</p>\s*<p>}i, "\n\n")
    |> String.replace(~r{<br\s*/?>}i, "\n")
    |> String.replace(~r{<[^>]+>}, "")
    |> unescape_entities()
  end

  defp unescape_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
    |> String.replace("&nbsp;", " ")
  end

  defp attachments(note), do: note |> Map.get("attachment", []) |> List.wrap()

  # AP attachment `url` may be a string or a Link object/array.
  defp attachment_url(%{"url" => url}) when is_binary(url), do: url
  defp attachment_url(%{"url" => %{"href" => href}}) when is_binary(href), do: href
  defp attachment_url(%{"url" => [%{"href" => href} | _]}) when is_binary(href), do: href
  defp attachment_url(%{"url" => [url | _]}) when is_binary(url), do: url
  defp attachment_url(_), do: nil

  defp visibility_for(note, opts) do
    case Keyword.get(opts, :visibility) do
      v when v in ["public", "unlisted", "private", "direct"] -> v
      _ -> derive_visibility(note)
    end
  end

  @public "https://www.w3.org/ns/activitystreams#Public"

  defp derive_visibility(note) do
    to = note |> Map.get("to", []) |> List.wrap()
    cc = note |> Map.get("cc", []) |> List.wrap()

    cond do
      @public in to -> "public"
      @public in cc -> "unlisted"
      true -> "private"
    end
  end

  defp published_ms(note) do
    with pub when is_binary(pub) <- note["published"],
         {:ok, dt, _} <- DateTime.from_iso8601(pub) do
      {:ok, DateTime.to_unix(dt, :millisecond)}
    else
      _ -> :error
    end
  end

  defp next_seq(seen_ms, ms) do
    seq = Map.get(seen_ms, ms, 0)
    {seq, Map.put(seen_ms, ms, seq + 1)}
  end

  defp status_exists?(id), do: Repo.exists?(from(s in Status, where: s.id == ^id))

  ## ---- file discovery ---------------------------------------------------

  defp find_outbox(root_dir) do
    [
      Path.join(root_dir, "outbox.json"),
      Path.join([root_dir, "**", "outbox.json"])
    ]
    |> Enum.flat_map(&Path.wildcard/1)
    |> List.first()
  end

  defp decode_outbox(file) do
    with {:ok, body} <- File.read(file),
         {:ok, decoded} <- Jason.decode(body) do
      decoded
      |> ordered_items()
      |> Enum.map(&object/1)
      |> Enum.reject(&is_nil/1)
    else
      _ ->
        Logger.warning("[mastodon-import] could not decode #{file}")
        []
    end
  end

  defp ordered_items(%{"orderedItems" => items}) when is_list(items), do: items
  defp ordered_items(%{"items" => items}) when is_list(items), do: items
  defp ordered_items(list) when is_list(list), do: list
  defp ordered_items(_), do: []

  defp resolve_media_path(_root_dir, url) when not is_binary(url), do: :error

  defp resolve_media_path(root_dir, url) do
    basename = url |> URI.parse() |> Map.get(:path, url) |> to_string() |> Path.basename()

    case Path.wildcard(Path.join([root_dir, "**", basename])) do
      [hit | _] -> {:ok, hit}
      [] -> :error
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
      _ -> "application/octet-stream"
    end
  end

  defp extract_zip(zip_path) do
    if File.regular?(zip_path) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "angler-mastodon-import-#{System.unique_integer([:positive])}"
        )

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
