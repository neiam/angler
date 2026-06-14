defmodule Angler.Media do
  @moduledoc """
  Media upload + lifecycle.

  `upload/3` accepts a `Plug.Upload` (or any map with `:path`, `:content_type`,
  `:filename`), validates the MIME against an allowlist, hashes the bytes,
  dedupes by `(profile_id, sha256)`, copies the file into local storage as the
  original variant, inserts a pending row, and enqueues
  `Angler.Media.Workers.ImageProcess`. The processor strips EXIF, resizes
  variants (`thumb`, `preview`), computes a blurhash, and marks the row ready.

  Image-only for now. Video uploads are rejected with `{:error, :unsupported_type}`.
  """

  import Ecto.Query, warn: false

  alias Angler.Media.Asset
  alias Angler.Media.Storage
  alias Angler.Media.Workers.ImageProcess
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses.Status

  @max_size_bytes 100 * 1_048_576

  @image_mimes ~w(image/jpeg image/png image/webp image/gif)
  @video_mimes ~w(video/mp4 video/webm video/quicktime)
  @magic_jpeg <<0xFF, 0xD8, 0xFF>>
  @magic_png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
  @magic_gif "GIF8"
  @magic_webp_riff "RIFF"

  ## Reads

  @spec get(integer()) :: Asset.t() | nil
  def get(id) when is_integer(id), do: Repo.get(Asset, id)

  @spec get_owned(integer(), integer()) :: Asset.t() | nil
  def get_owned(id, profile_id) when is_integer(id) and is_integer(profile_id) do
    Repo.get_by(Asset, id: id, profile_id: profile_id)
  end

  ## Writes

  @doc """
  Accept an upload and persist it.

  `upload` is a `%Plug.Upload{}` or compatible map.
  """
  @spec upload(Profile.t(), map(), map()) ::
          {:ok, Asset.t()} | {:error, atom()}
  def upload(%Profile{id: profile_id}, upload, params \\ %{}) do
    with {:ok, path} <- fetch_path(upload),
         {:ok, declared_type} <- fetch_type(upload),
         {:ok, magic} <- read_magic(path),
         {:ok, sniffed_type} <- sniff_mime(magic, declared_type),
         :ok <- check_supported(sniffed_type),
         {:ok, size} <- check_size(path),
         {:ok, sha} <- hash(path) do
      case Repo.get_by(Asset, profile_id: profile_id, sha256: sha) do
        # A clean, unattached prior upload of the same bytes — reuse as-is.
        %Asset{status_id: nil, status: status} = existing when status != "deleted" ->
          {:ok, existing}

        # The sha+profile row is unique, so we can't insert a second copy and
        # we can't reuse one that's stale (soft-deleted, or left attached to a
        # since-deleted status). Reclaim it so the same image can be posted or
        # set as an avatar again — this is what makes re-uploads after a delete
        # work.
        %Asset{} = existing ->
          reclaim(existing, profile_id, path)

        nil ->
          do_insert(profile_id, path, sha, sniffed_type, size, params)
      end
    end
  end

  # Reuse the row if it's still live-attached (a genuine duplicate of a current
  # post's media); otherwise free it: re-store the bytes (in case the file was
  # removed) and reset to a fresh, unattached, reprocessable state.
  defp reclaim(%Asset{} = asset, profile_id, src_path) do
    if attached_to_live_status?(asset) do
      {:ok, asset}
    else
      case Path.basename(asset.path_original || "") do
        "" -> :ok
        filename -> Storage.put(profile_id, :original, filename, src_path)
      end

      asset
      |> Ecto.Changeset.change(
        status: "pending",
        status_id: nil,
        unattached_at: DateTime.utc_now()
      )
      |> Repo.update()
      |> case do
        {:ok, reclaimed} ->
          {:ok, _} = ImageProcess.enqueue(reclaimed.id)
          {:ok, reclaimed}

        err ->
          err
      end
    end
  end

  defp attached_to_live_status?(%Asset{status_id: nil}), do: false

  defp attached_to_live_status?(%Asset{status_id: status_id}),
    do: Repo.exists?(from(s in Status, where: s.id == ^status_id and is_nil(s.deleted_at)))

  @doc """
  Update an asset's caption (alt text). Owner-only.
  """
  @spec update_caption(Asset.t(), Profile.t(), String.t() | nil) ::
          {:ok, Asset.t()} | {:error, term()}
  def update_caption(%Asset{profile_id: pid} = asset, %Profile{id: pid}, caption) do
    asset
    |> Ecto.Changeset.change(caption: caption)
    |> Repo.update()
  end

  def update_caption(_, _, _), do: {:error, :forbidden}

  @doc """
  Atomically attach a list of media ids to a status. Only assets owned by
  `profile_id` and not yet attached to another status are taken; returns
  `{:ok, [Asset.t()]}` on success or `{:error, :unattachable}` if any id was
  invalid/not-owned/already-attached.
  """
  @spec attach_to_status([integer()], integer(), integer()) ::
          {:ok, [Asset.t()]} | {:error, :unattachable}
  def attach_to_status([], _, _), do: {:ok, []}

  def attach_to_status(ids, status_id, profile_id)
      when is_list(ids) and is_integer(status_id) and is_integer(profile_id) do
    {n, rows} =
      from(a in Asset,
        where:
          a.id in ^ids and
            a.profile_id == ^profile_id and
            is_nil(a.status_id) and
            a.status != "deleted",
        select: a
      )
      |> Repo.update_all(set: [status_id: status_id, unattached_at: nil])

    if n == length(ids), do: {:ok, rows}, else: {:error, :unattachable}
  end

  @doc """
  Persist AP attachment objects from a federated Note as remote `Asset` rows
  linked to `status_id`. Remote media is referenced by URL — never downloaded —
  so the rendered attachment points straight at the origin. Attachments without
  a usable URL/media type are skipped; insert failures are dropped silently.
  """
  @spec ingest_remote_attachments(list() | nil, integer(), integer()) :: {:ok, [Asset.t()]}
  def ingest_remote_attachments(attachments, status_id, profile_id)
      when is_list(attachments) and is_integer(status_id) and is_integer(profile_id) do
    rows =
      attachments
      |> Enum.map(&remote_attachment_attrs(&1, status_id, profile_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(fn attrs ->
        case Asset.changeset(attrs) |> Repo.insert() do
          {:ok, asset} -> [asset]
          {:error, _} -> []
        end
      end)

    {:ok, rows}
  end

  def ingest_remote_attachments(_, _, _), do: {:ok, []}

  defp remote_attachment_attrs(att, status_id, profile_id) when is_map(att) do
    with {url, link_type} <- attachment_url(att),
         media_type when is_binary(media_type) <- att["mediaType"] || link_type do
      %{
        profile_id: profile_id,
        status_id: status_id,
        media_type: media_type,
        storage: "remote",
        status: "ready",
        remote_url: url,
        caption: att["name"] || att["summary"],
        blurhash: att["blurhash"],
        width: positive_int(att["width"]),
        height: positive_int(att["height"])
      }
    else
      _ -> nil
    end
  end

  defp remote_attachment_attrs(_, _, _), do: nil

  # AP `url` may be a plain string, a Link object, or a list of either.
  defp attachment_url(%{"url" => url}), do: pick_url(url)
  defp attachment_url(%{"href" => href}) when is_binary(href), do: {href, nil}
  defp attachment_url(_), do: nil

  defp pick_url(url) when is_binary(url), do: {url, nil}
  defp pick_url(%{"href" => href} = link) when is_binary(href), do: {href, link["mediaType"]}
  defp pick_url([first | _]), do: pick_url(first)
  defp pick_url(_), do: nil

  defp positive_int(n) when is_integer(n) and n > 0, do: n
  defp positive_int(_), do: nil

  ## Internals

  defp fetch_path(%{path: p}) when is_binary(p), do: {:ok, p}
  defp fetch_path(_), do: {:error, :no_file}

  defp fetch_type(%{content_type: t}) when is_binary(t), do: {:ok, t}
  defp fetch_type(_), do: {:error, :no_content_type}

  defp read_magic(path) do
    case File.open(path, [:read, :binary], fn f -> IO.binread(f, 16) end) do
      {:ok, bin} when is_binary(bin) -> {:ok, bin}
      _ -> {:error, :unreadable}
    end
  end

  defp sniff_mime(<<@magic_jpeg, _::binary>>, _), do: {:ok, "image/jpeg"}
  defp sniff_mime(<<@magic_png, _::binary>>, _), do: {:ok, "image/png"}
  defp sniff_mime(<<@magic_gif, _::binary>>, _), do: {:ok, "image/gif"}
  defp sniff_mime(<<@magic_webp_riff, _::32, "WEBP", _::binary>>, _), do: {:ok, "image/webp"}

  defp sniff_mime(<<_::32, "ftyp", brand::binary-size(4), _::binary>>, declared) do
    cond do
      brand in ["qt  ", "qtco"] -> {:ok, "video/quicktime"}
      declared == "video/quicktime" -> {:ok, "video/quicktime"}
      true -> {:ok, "video/mp4"}
    end
  end

  defp sniff_mime(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>, _), do: {:ok, "video/webm"}
  defp sniff_mime(_, _), do: {:error, :unsupported_type}

  defp check_supported(t) when t in @image_mimes, do: :ok
  defp check_supported(t) when t in @video_mimes, do: :ok
  defp check_supported(_), do: {:error, :unsupported_type}

  defp check_size(path) do
    case File.stat(path) do
      {:ok, %{size: s}} when s <= @max_size_bytes -> {:ok, s}
      {:ok, %{size: _}} -> {:error, :too_large}
      _ -> {:error, :unreadable}
    end
  end

  defp hash(path) do
    state =
      File.stream!(path, 65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))

    {:ok, :crypto.hash_final(state)}
  end

  defp do_insert(profile_id, src_path, sha, mime, size, params) do
    ext = ext_for(mime)
    filename = Base.encode16(sha, case: :lower) <> "." <> ext

    {:ok, stored_path} = Storage.put(profile_id, :original, filename, src_path)

    attrs = %{
      profile_id: profile_id,
      media_type: mime,
      sha256: sha,
      size_bytes: size,
      storage: "local",
      status: "pending",
      path_original: stored_path,
      caption: Map.get(params, "description"),
      unattached_at: DateTime.utc_now()
    }

    case Asset.changeset(attrs) |> Repo.insert() do
      {:ok, asset} ->
        {:ok, _} = ImageProcess.enqueue(asset.id)
        {:ok, asset}

      err ->
        err
    end
  end

  defp ext_for("image/jpeg"), do: "jpg"
  defp ext_for("image/png"), do: "png"
  defp ext_for("image/webp"), do: "webp"
  defp ext_for("image/gif"), do: "gif"
  defp ext_for("video/mp4"), do: "mp4"
  defp ext_for("video/webm"), do: "webm"
  defp ext_for("video/quicktime"), do: "mov"
end
