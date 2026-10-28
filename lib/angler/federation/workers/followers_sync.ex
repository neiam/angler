defmodule Angler.Federation.Workers.FollowersSync do
  @moduledoc """
  Runs `Angler.Federation.FollowersSync.synchronize/4` for a remote actor
  whose followers digest disagreed with ours. Unique per sender for 15
  minutes, which is the cooldown: a busy actor is fetched at most that often.
  """

  use Oban.Worker,
    queue: :federation_inbound,
    max_attempts: 3,
    unique: [period: 900, fields: [:args], keys: [:sender_id]]

  alias Angler.Federation.FollowersSync
  alias Angler.Profiles.Profile
  alias Angler.Repo

  @spec enqueue(integer(), String.t(), String.t(), String.t()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(sender_id, collection_id, url, digest) do
    %{
      "sender_id" => sender_id,
      "collection_id" => collection_id,
      "url" => url,
      "digest" => digest
    }
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"sender_id" => id} = args}) do
    case Repo.get(Profile, id) do
      nil ->
        :ok

      sender ->
        _ = FollowersSync.synchronize(sender, args["collection_id"], args["url"], args["digest"])
    end

    :ok
  end
end
