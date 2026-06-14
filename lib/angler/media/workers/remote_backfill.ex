defmodule Angler.Media.Workers.RemoteBackfill do
  @moduledoc """
  One-shot backfill for federated posts that were mirrored before remote
  media ingestion existed: re-dereferences the original AP object and
  persists its `attachment` array as remote `Asset` rows.

  One job per status (`unique` on `status_id`) so the fan-out is idempotent
  and retries are isolated. Candidates are remote, non-deleted statuses whose
  `type` implies media but which currently have no `media_attachments` —
  `enqueue_all/0` finds them and inserts a job each.

  Remote media is referenced by URL, never downloaded; the fetch is unsigned,
  mirroring `Angler.Federation.Actor` dereferencing.
  """

  use Oban.Worker,
    queue: :federation_inbound,
    max_attempts: 5,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  import Ecto.Query, warn: false
  require Logger

  alias Angler.Federation.HTTP, as: FedHTTP
  alias Angler.Media
  alias Angler.Media.Asset
  alias Angler.Repo
  alias Angler.Statuses.Status

  # Set by `Statuses.Federation` when the inbound Note carried attachments.
  @media_types ~w(photo photo:album video video:album)

  @doc """
  Enqueue a backfill job for every remote status that looks like it should
  have media but has none. Returns the number of jobs inserted.

  Uses `Oban.insert/1`, so the Oban supervisor must be running (true under the
  mix task / live app). For release `eval` where only the repo is up, use
  `enqueue_all_via_repo/0`.
  """
  @spec enqueue_all() :: non_neg_integer()
  def enqueue_all do
    ids = candidate_ids()
    Enum.each(ids, &enqueue/1)
    length(ids)
  end

  @doc """
  Like `enqueue_all/0` but inserts the job rows straight through the repo,
  so it works under `Ecto.Migrator.with_repo` (release `eval`) where Oban
  itself isn't started. Skips Oban's unique dedup — safe here because the
  worker re-checks for existing media before fetching.
  """
  @spec enqueue_all_via_repo() :: non_neg_integer()
  def enqueue_all_via_repo do
    ids = candidate_ids()
    Enum.each(ids, fn id -> %{"status_id" => id} |> __MODULE__.new() |> Repo.insert() end)
    length(ids)
  end

  @doc "Status ids that are remote, media-typed, undeleted, and asset-less."
  @spec candidate_ids() :: [integer()]
  def candidate_ids do
    from(s in Status,
      left_join: a in Asset,
      on: a.status_id == s.id,
      where:
        s.local == false and is_nil(s.deleted_at) and not is_nil(s.uri) and
          s.type in ^@media_types,
      group_by: s.id,
      having: count(a.id) == 0,
      select: s.id
    )
    |> Repo.all()
  end

  @spec enqueue(integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(status_id) when is_integer(status_id) do
    %{"status_id" => status_id} |> __MODULE__.new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"status_id" => status_id}}) do
    case Repo.get(Status, status_id) do
      nil ->
        :ok

      %Status{deleted_at: %DateTime{}} ->
        :ok

      %Status{uri: uri} = status when is_binary(uri) ->
        backfill(status)

      _ ->
        :ok
    end
  end

  defp backfill(%Status{} = status) do
    # Re-check under the job: a concurrent live ingest may have filled it.
    if has_media?(status.id) do
      :ok
    else
      case FedHTTP.fetch(status.uri) do
        {:ok, %{"attachment" => attachment}} ->
          {:ok, rows} =
            Media.ingest_remote_attachments(
              List.wrap(attachment),
              status.id,
              status.profile_id
            )

          Logger.info("backfilled #{length(rows)} attachment(s) for status #{status.id}")
          :ok

        {:ok, _no_attachment} ->
          :ok

        {:error, reason} ->
          Logger.warning("media backfill fetch failed for #{status.uri}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp has_media?(status_id) do
    Repo.exists?(from(a in Asset, where: a.status_id == ^status_id))
  end
end
