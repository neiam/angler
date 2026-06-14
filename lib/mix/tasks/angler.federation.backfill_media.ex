defmodule Mix.Tasks.Angler.Federation.BackfillMedia do
  @moduledoc """
  Backfill remote media for federated posts that were mirrored before remote
  attachment ingestion existed.

      mix angler.federation.backfill_media

  Finds remote, undeleted, media-typed statuses that have no attachments and
  enqueues one `Angler.Media.Workers.RemoteBackfill` job each (queue
  `:federation_inbound`). Each job re-dereferences the origin AP object and
  persists its `attachment` array. Remote media is referenced by URL, never
  downloaded.

  The release-safe equivalent is
  `bin/angler eval 'Angler.Release.backfill_remote_media()'`.
  """

  use Mix.Task

  alias Angler.Media.Workers.RemoteBackfill

  @shortdoc "Enqueue remote-media backfill for pre-existing federated posts"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    count = RemoteBackfill.enqueue_all()
    Mix.shell().info("Enqueued #{count} media-backfill job(s).")
  end
end
