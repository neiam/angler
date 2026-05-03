defmodule Angler.Federation.Workers.ActivityHandler do
  @moduledoc """
  Single dispatcher for trusted, signature-verified inbound activities.

  Each activity type fans out to a domain function in the appropriate context.
  This slice supports `Follow`, `Undo Follow`, `Update Person`, and routes
  `Delete` activities to `DeleteWorker`. Other verbs are logged + dropped
  (they'll get handlers in subsequent slices).

  See plans/federation/queues/activity_handler.md.
  """

  use Oban.Worker,
    queue: :federation_inbound,
    max_attempts: 3

  require Logger

  alias Angler.Federation.Workers.DeleteWorker
  alias Angler.Follows
  alias Angler.Likes
  alias Angler.Profiles
  alias Angler.Reblogs
  alias Angler.Statuses

  @spec enqueue(map(), String.t(), integer() | nil) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(payload, actor_url, recipient_id) do
    %{
      "payload" => payload,
      "actor_url" => actor_url,
      "recipient_id" => recipient_id
    }
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"payload" => payload, "actor_url" => actor_url}
      }) do
    dispatch(payload, actor_url)
  end

  defp dispatch(%{"type" => "Follow"} = activity, actor_url) do
    Follows.Federation.handle_follow(activity, actor_url)
  end

  defp dispatch(%{"type" => "Undo", "object" => %{"type" => "Follow"}} = activity, actor_url) do
    Follows.Federation.handle_undo_follow(activity, actor_url)
  end

  defp dispatch(%{"type" => "Undo", "object" => %{"type" => "Like"}} = activity, actor_url) do
    Likes.Federation.handle_undo_like(activity, actor_url)
  end

  defp dispatch(%{"type" => "Undo", "object" => %{"type" => "Announce"}} = activity, actor_url) do
    Reblogs.Federation.handle_undo_announce(activity, actor_url)
  end

  defp dispatch(
         %{"type" => "Accept", "object" => %{"type" => "Follow", "id" => id}} = _activity,
         _actor_url
       ) do
    # Inbound Accept of a Follow we sent. The id matches our outbound
    # Follower.remote_url; flip the row to accepted + bump counters.
    case Follows.accept_remote!(id) do
      {:ok, _follower} -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp dispatch(%{"type" => "Accept", "object" => id} = _activity, _actor_url)
       when is_binary(id) do
    # Some peers Accept by passing just the Follow id as a bare string.
    case Follows.accept_remote!(id) do
      {:ok, _follower} -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp dispatch(%{"type" => "Accept"}, _actor_url), do: :ok

  defp dispatch(%{"type" => "Update", "object" => %{"type" => "Person"}} = activity, actor_url) do
    Profiles.Federation.handle_update(activity, actor_url)
  end

  defp dispatch(%{"type" => "Update", "object" => %{"type" => t}} = activity, actor_url)
       when t in ["Note", "Question"] do
    Statuses.Federation.handle_update(activity, actor_url)
  end

  defp dispatch(%{"type" => "Create"} = activity, actor_url) do
    Statuses.Federation.handle_create(activity, actor_url)
  end

  defp dispatch(%{"type" => "Like"} = activity, actor_url) do
    Likes.Federation.handle_like(activity, actor_url)
  end

  defp dispatch(%{"type" => "Announce"} = activity, actor_url) do
    Reblogs.Federation.handle_announce(activity, actor_url)
  end

  defp dispatch(%{"type" => "Delete"} = activity, _actor_url) do
    # Re-route to the dedicated worker. This branch is rarely hit because the
    # InboxController could route Delete directly to DeleteWorker, but keeping
    # the dispatch unified means the inbox code path stays simple.
    DeleteWorker.enqueue(activity)
  end

  defp dispatch(%{"type" => type} = activity, actor_url) do
    Logger.info(
      "Unhandled federation activity type=#{type} actor=#{actor_url} id=#{activity["id"]}"
    )

    :ok
  end

  defp dispatch(_, _), do: :ok
end
