defmodule Angler.Federation.Workers.Backfill do
  @moduledoc """
  Runs `Angler.Federation.Backfill` for one remote profile in the background
  and broadcasts the outcome on `topic/1`, which `AnglerWeb.ProfileLive`
  listens on to refresh the page. One run per profile at a time.
  """

  use Oban.Worker,
    queue: :federation_inbound,
    max_attempts: 1,
    unique: [
      period: :infinity,
      fields: [:args],
      keys: [:profile_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Angler.Federation.Backfill
  alias Angler.Profiles

  @spec topic(integer()) :: String.t()
  def topic(profile_id), do: "backfill:#{profile_id}"

  @doc "Queue a backfill; `{:ok, %Oban.Job{conflict?: true}}` if one is already pending."
  @spec enqueue(integer(), pos_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(profile_id, limit \\ Backfill.default_limit()) do
    %{"profile_id" => profile_id, "limit" => limit} |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => id} = args}) do
    result =
      case Profiles.get_profile(id) do
        nil -> {:error, :not_found}
        profile -> Backfill.run(profile, limit: args["limit"] || Backfill.default_limit())
      end

    Phoenix.PubSub.broadcast(Angler.PubSub, topic(id), {:backfill_done, result})
    :ok
  end
end
