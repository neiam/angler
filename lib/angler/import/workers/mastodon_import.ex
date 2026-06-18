defmodule Angler.Import.Workers.MastodonImport do
  @moduledoc """
  Async driver for `Angler.Import.Mastodon`, mirroring
  `Angler.Import.Workers.InstagramImport`: a settings page stages the uploaded
  export `.zip`, calls `enqueue/3`, and subscribes to `topic/1` for completion
  (`{:mastodon_import_done, summary}` / `{:mastodon_import_failed, reason}`).
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query, only: [from: 2]
  require Logger

  alias Angler.Import.Mastodon
  alias Angler.Profiles.Profile
  alias Angler.Repo

  @non_terminal ~w(available scheduled executing retryable)

  @spec topic(integer()) :: String.t()
  def topic(profile_id), do: "imports:mastodon:#{profile_id}"

  @spec enqueue(integer(), Path.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(profile_id, zip_path, opts \\ []) when is_integer(profile_id) do
    %{"profile_id" => profile_id, "zip_path" => zip_path, "opts" => Map.new(opts)}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @spec pending?(integer()) :: boolean()
  def pending?(profile_id) when is_integer(profile_id) do
    Repo.exists?(
      from(j in Oban.Job,
        where:
          j.worker == "Angler.Import.Workers.MastodonImport" and
            j.state in ^@non_terminal and
            fragment("?->>'profile_id' = ?", j.args, ^to_string(profile_id))
      )
    )
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id, "zip_path" => zip_path} = args}) do
    opts = args |> Map.get("opts", %{}) |> decode_opts()

    case Repo.get(Profile, profile_id) do
      %Profile{domain: nil} = profile ->
        try do
          case Mastodon.import_zip(profile, zip_path, opts) do
            {:ok, summary} ->
              Logger.info("[mastodon-import] profile #{profile_id}: #{inspect(summary)}")
              broadcast(profile_id, {:mastodon_import_done, summary})
              :ok

            {:error, reason} ->
              broadcast(profile_id, {:mastodon_import_failed, reason})
              {:error, reason}
          end
        after
          File.rm_rf(zip_path)
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

  defp decode_opts(map) when is_map(map) do
    [
      {:visibility, map["visibility"]},
      {:language, map["language"]},
      {:dry_run, map["dry_run"]}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end
end
