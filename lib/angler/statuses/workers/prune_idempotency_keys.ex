defmodule Angler.Statuses.Workers.PruneIdempotencyKeys do
  @moduledoc "Hourly: delete `Idempotency-Key` rows older than their hour."

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    _ = Angler.Statuses.Idempotency.prune()
    :ok
  end
end
