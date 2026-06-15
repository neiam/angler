defmodule Mix.Tasks.Angler.ImportInstagram do
  @moduledoc """
  Import an Instagram data export (JSON format) into a local profile.

      mix angler.import_instagram <export.zip | export_dir> <username> [opts]

  `<username>` is the local profile to import into. The export must be the
  **JSON** "Download Your Information" archive (a `.zip`) or an already-extracted
  directory containing `media/` and `posts_1.json`.

  Posts are created **backdated** to their original Instagram timestamp and are
  **not** federated or fanned into home timelines — they appear in the author's
  profile grid only (silent backfill). Re-running over the same export is safe;
  already-imported posts are skipped and media is de-duplicated.

  ## Options

    * `--visibility public|unlisted|private` — visibility for imported posts
      (default `public`).
    * `--language en` — default language code (default `en`).
    * `--dry-run` — parse and report counts without writing anything.

  The release-safe equivalent is:

      bin/angler eval 'Angler.Import.Instagram.import_zip(profile, path, opts)'

  Media is processed asynchronously by the `:media` Oban queue; this task waits
  briefly for the queue to drain before exiting.
  """

  use Mix.Task

  alias Angler.Import.Instagram
  alias Angler.Profiles

  @shortdoc "Import an Instagram (JSON) export into a local profile"

  @switches [visibility: :string, language: :string, dry_run: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, switches: @switches)

    case args do
      [source, username] ->
        Mix.Task.run("app.start")
        Logger.configure(level: :warning)
        do_run(source, username, opts)

      _ ->
        Mix.raise("Usage: mix angler.import_instagram <export.zip|dir> <username> [--dry-run]")
    end
  end

  defp do_run(source, username, opts) do
    case Profiles.get_local_by_username(username) do
      nil ->
        Mix.raise("No local profile found for username #{inspect(username)}")

      profile ->
        import_opts = [
          visibility: opts[:visibility] || "public",
          language: opts[:language] || "en",
          dry_run: opts[:dry_run] || false,
          on_progress: &progress/2
        ]

        result =
          if File.dir?(source) do
            Instagram.import_dir(profile, source, import_opts)
          else
            Instagram.import_zip(profile, source, import_opts)
          end

        report(result, opts[:dry_run] || false)
    end
  end

  defp progress(idx, total) when rem(idx, 25) == 0 or idx == total do
    Mix.shell().info("  … #{idx}/#{total} posts")
  end

  defp progress(_idx, _total), do: :ok

  defp report({:ok, s}, dry_run?) do
    prefix = if dry_run?, do: "[dry run] ", else: ""

    Mix.shell().info("""
    #{prefix}Instagram import complete:
      posts seen: #{s.posts}
      imported:   #{s.imported}
      skipped:    #{s.skipped} (already present)
      failed:     #{s.failed}
    """)

    if s.errors != [] do
      Mix.shell().info("First errors:")
      s.errors |> Enum.take(10) |> Enum.each(&Mix.shell().info("  - #{&1}"))
    end

    unless dry_run? do
      Mix.shell().info("Media is processing in the background (:media queue).")
    end
  end

  defp report({:error, :no_posts_file}, _) do
    Mix.raise("No posts JSON found. Is this a JSON-format export with a posts_1.json?")
  end

  defp report({:error, reason}, _) do
    Mix.raise("Import failed: #{inspect(reason)}")
  end
end
