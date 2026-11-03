defmodule Angler.Federation.Workers.ActorRefresh do
  @moduledoc """
  Re-fetch a cached remote actor in the background (`Angler.Federation.Actor`
  queues it when `resolve/1` hands back a stale profile), picking up a new
  name, bio, avatar or key. Unique per actor for a day.
  """

  use Oban.Worker,
    queue: :federation_inbound,
    max_attempts: 2,
    unique: [period: 86_400, fields: [:args], keys: [:actor_url]]

  alias Angler.Federation.Actor

  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(actor_url) when is_binary(actor_url) do
    %{"actor_url" => actor_url} |> __MODULE__.new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"actor_url" => url}}) do
    case Actor.refresh(url) do
      {:ok, _} -> :ok
      # Gone or unreachable: try again tomorrow, when it's next resolved.
      {:error, _} -> :ok
    end
  end
end
