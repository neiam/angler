defmodule Angler.Statuses.Workers.ScheduledFire do
  @moduledoc """
  Cron worker (every minute) that fires due scheduled statuses. The actual
  claim + post is done inside `Angler.Statuses.Scheduling.fire_due/0`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Angler.Statuses.Scheduling

  @impl Oban.Worker
  def perform(_job) do
    {ok, fail} = Scheduling.fire_due()

    :telemetry.execute(
      [:angler, :statuses, :scheduled_fire],
      %{ok: ok, failure: fail}
    )

    :ok
  end
end
