defmodule Angler.Federation.Workers.InboxWorker do
  @moduledoc """
  Shared-inbox worker. Mirrors `InboxValidator` but is invoked from
  `POST /f/inbox` where there's no specific local recipient — the activity is
  addressed to a public collection or to multiple users via `to`/`cc`.

  We delegate the heavy lifting (sig verify + dedup + dispatch) to
  `InboxValidator` so there's one canonical implementation.
  """

  use Oban.Worker,
    queue: :federation_inbound,
    max_attempts: 3

  alias Angler.Federation.Workers.InboxValidator

  @doc "Enqueue a shared-inbox activity."
  @spec enqueue(map(), binary(), map(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(headers, raw_body, payload, request_path) do
    InboxValidator.enqueue(nil, headers, raw_body, payload, request_path)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    # Defer to the shared logic. Should never actually fire because `enqueue/4`
    # routes through InboxValidator directly, but kept for explicitness in the
    # worker module list and for future per-shared-inbox concerns (e.g.,
    # fan-out across multiple local recipients of the same payload).
    InboxValidator.perform(job)
  end
end
