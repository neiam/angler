defmodule Angler.Stories.Workers.Expire do
  @moduledoc """
  Cron worker (every minute) that flips `active: false` on stories whose
  `expires_at` is in the past. Cheap update_all in one statement.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  alias Angler.Stories

  @impl Oban.Worker
  def perform(_job) do
    expired = Stories.expire_due()
    :telemetry.execute([:angler, :stories, :expire], %{expired: expired})
    :ok
  end
end
