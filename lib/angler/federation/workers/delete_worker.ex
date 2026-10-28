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

  alias Angler.Federation.Actor
  alias Angler.Profiles
  alias Angler.Quotes
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

  # The inbox has already bound the signature to `actor`, so it is who sent
  # this. Every branch below only lets an actor delete what it owns.
  defp do_handle(%{"actor" => actor, "object" => %{"type" => "Person", "id" => person}})
       when is_binary(actor) do
    if Actor.same_actor?(person, actor),
      do: Profiles.Federation.handle_delete_person(actor),
      else: :ok
  end

  # Mastodon deletes an account with `object` as the bare actor URL.
  defp do_handle(%{"actor" => actor, "object" => actor}) when is_binary(actor) do
    Profiles.Federation.handle_delete_person(actor)
  end

  defp do_handle(%{"actor" => actor, "object" => %{"type" => "Tombstone", "id" => object_id}})
       when is_binary(actor) and is_binary(object_id) do
    tombstone(object_id, actor)
  end

  # Some peers send `Delete` with just `object` as the URL string + no inner
  # type. In that case we treat it as a Tombstone delete of the URL.
  defp do_handle(%{"actor" => actor, "object" => object_id})
       when is_binary(actor) and is_binary(object_id) do
    tombstone(object_id, actor)
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

  # A deleted post may have been a quote of ours: its stamp goes with it.
  defp tombstone(object_id, actor) do
    :ok = Quotes.forget_quote(actor, object_id)
    Statuses.Federation.handle_delete_tombstone(object_id, actor)
  end
end
