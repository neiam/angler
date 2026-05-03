defmodule Angler.Federation.Workers.DeleteWorker do
  @moduledoc """
  Handles inbound `Delete` activities.

  Pixelfed splits these onto separate Oban queues by inner object type
  because Delete floods can overwhelm the regular inbox queue. We follow the
  same pattern via `priority`/queue choice.

  This slice supports `Delete Person` and `Delete Tombstone` (status purge).
  Story delete will land with the stories grouping.

  See plans/federation/queues/delete_worker.md.
  """

  use Oban.Worker,
    queue: :federation_inbound,
    max_attempts: 5

  require Logger

  alias Angler.Profiles
  alias Angler.Statuses

  @spec enqueue(map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(activity) do
    %{"activity" => activity}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"activity" => activity}}) do
    do_handle(activity)
  end

  defp do_handle(%{"object" => %{"type" => "Person", "id" => actor_url}}) do
    Profiles.Federation.handle_delete_person(actor_url)
  end

  defp do_handle(%{"object" => %{"type" => "Tombstone", "id" => object_id}}) do
    Statuses.Federation.handle_delete_tombstone(object_id)
  end

  # Some peers send `Delete` with just `object` as the URL string + no inner
  # type. In that case we treat it as a Tombstone delete of the URL.
  defp do_handle(%{"object" => object_id}) when is_binary(object_id) do
    Statuses.Federation.handle_delete_tombstone(object_id)
  end

  defp do_handle(%{"object" => %{"type" => "Story"}} = activity) do
    Logger.info(
      "Delete Story received but stories grouping not yet implemented: #{activity["id"]}"
    )

    :ok
  end

  defp do_handle(activity) do
    Logger.info("Unhandled Delete activity object: #{inspect(activity["object"])}")
    :ok
  end
end
