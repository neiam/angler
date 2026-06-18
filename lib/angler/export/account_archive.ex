defmodule Angler.Export.AccountArchive do
  @moduledoc """
  Builds a downloadable account-data archive for a local profile — the export
  counterpart to `Angler.Import.Instagram`.

  The archive is a `.zip` containing:

    * `actor.json`     — the AP actor (`ActorBuilder.person/1`)
    * `outbox.json`    — an `OrderedCollection` of `Create` activities, one per
      authored status (built with `NoteBuilder.create_activity/2`, the same
      serializer federation uses, so the export round-trips through our own
      importer and other AP software)
    * `posts.json`     — the bare AP `Note` objects (no `Create` envelope), a
      lighter post-only export for backup/portability
    * `media/…`        — the original bytes of locally-stored attachments

  The serialization reuses the federation builders so an export stays
  byte-compatible with what we publish over ActivityPub.
  """

  alias Angler.Export.PostExport
  alias Angler.Federation.ActorBuilder
  alias Angler.Media.Storage.Local
  alias Angler.Profiles.Profile
  alias Angler.Statuses

  @type summary :: %{count: non_neg_integer(), media: non_neg_integer(), path: Path.t()}

  @doc """
  Build the archive for `profile`. Returns `{:ok, summary}` with the path to the
  written `.zip`. The caller owns the file (serve it, then delete it).

  `opts[:dir]` overrides the output directory (defaults to a temp dir).
  """
  @spec build(Profile.t(), keyword()) :: {:ok, summary()} | {:error, term()}
  def build(profile, opts \\ [])

  def build(%Profile{domain: nil} = profile, opts) do
    statuses = Statuses.list_for_export(profile.id)

    actor = ActorBuilder.person(profile)
    notes = Enum.map(statuses, &PostExport.note(&1, profile))
    activities = Enum.map(statuses, &PostExport.create_activity(&1, profile))

    files =
      [
        {~c"actor.json", encode(actor)},
        {~c"outbox.json", encode(outbox(actor["id"], activities))},
        {~c"posts.json", encode(notes)}
      ] ++ media_files(statuses)

    dir = Keyword.get(opts, :dir, default_dir(profile.id))
    File.mkdir_p!(dir)
    zip_path = Path.join(dir, "angler-export-#{profile.username}.zip")

    case :zip.create(String.to_charlist(zip_path), files) do
      {:ok, _} ->
        {:ok, %{count: length(statuses), media: count_media(statuses), path: zip_path}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def build(%Profile{}, _opts), do: {:error, :not_local_profile}

  @doc "The directory archives for `profile_id` are written to (and served from)."
  @spec default_dir(integer()) :: Path.t()
  def default_dir(profile_id) do
    Path.join([Local.root(), "exports", Integer.to_string(profile_id)])
  end

  ## Internals

  defp outbox(actor_id, activities) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => to_string(actor_id) <> "/outbox",
      "type" => "OrderedCollection",
      "totalItems" => length(activities),
      "orderedItems" => activities
    }
  end

  # Copy each local attachment's original bytes into `media/<filename>`. Remote
  # (referenced-by-URL) media and missing files are skipped.
  defp media_files(statuses) do
    statuses
    |> Enum.flat_map(& &1.media_attachments)
    |> Enum.flat_map(fn asset ->
      with "local" <- asset.storage,
           p when is_binary(p) <- asset.path_original,
           abs = Path.join(Local.root(), p),
           true <- File.regular?(abs),
           {:ok, bytes} <- File.read(abs) do
        [{String.to_charlist("media/" <> Path.basename(p)), bytes}]
      else
        _ -> []
      end
    end)
  end

  defp count_media(statuses) do
    statuses |> Enum.flat_map(& &1.media_attachments) |> length()
  end

  defp encode(term), do: Jason.encode!(term, pretty: true)
end
