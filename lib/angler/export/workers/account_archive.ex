defmodule Angler.Export.Workers.AccountArchive do
  @moduledoc """
  Async driver for `Angler.Export.AccountArchive`. Mirrors the Instagram-import
  worker: a settings page enqueues `enqueue/1`, then subscribes to `topic/1` to
  learn when the `.zip` is ready (`{:account_export_done, summary}`) or failed
  (`{:account_export_failed, reason}`).

  Single attempt on the `:default` queue — an export is cheap to re-request and
  we don't want a transient failure to rebuild a large archive on retry.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query, only: [from: 2]
  require Logger

  alias Angler.Export.AccountArchive
  alias Angler.Profiles.Profile
  alias Angler.Repo

  @non_terminal ~w(available scheduled executing retryable)

  @spec topic(integer()) :: String.t()
  def topic(profile_id), do: "exports:account:#{profile_id}"

  @spec enqueue(integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(profile_id) when is_integer(profile_id) do
    %{"profile_id" => profile_id}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @spec pending?(integer()) :: boolean()
  def pending?(profile_id) when is_integer(profile_id) do
    Repo.exists?(
      from(j in Oban.Job,
        where:
          j.worker == "Angler.Export.Workers.AccountArchive" and
            j.state in ^@non_terminal and
            fragment("?->>'profile_id' = ?", j.args, ^to_string(profile_id))
      )
    )
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id}}) do
    case Repo.get(Profile, profile_id) do
      %Profile{domain: nil} = profile ->
        case AccountArchive.build(profile) do
          {:ok, summary} ->
            Logger.info(
              "[account-export] profile #{profile_id}: #{inspect(Map.delete(summary, :path))}"
            )

            broadcast(profile_id, {:account_export_done, summary})
            :ok

          {:error, reason} ->
            broadcast(profile_id, {:account_export_failed, reason})
            {:error, reason}
        end

      %Profile{} ->
        {:cancel, :not_local_profile}

      nil ->
        {:cancel, :profile_not_found}
    end
  end

  defp broadcast(profile_id, message) do
    Phoenix.PubSub.broadcast(Angler.PubSub, topic(profile_id), message)
  end
end
