defmodule Angler.Import.Workers.InstagramImport do
  @moduledoc """
  Async driver for `Angler.Import.Instagram` — the seam a future settings-page
  upload UI enqueues into.

  Given a profile id and a path to an already-uploaded export `.zip`, it runs the
  import in the background and removes the source archive when done. The web flow
  is responsible for storing the user's upload somewhere readable and calling
  `enqueue/3`.

  Long-running by nature; runs on the `:default` queue with a single attempt
  (imports are idempotent, but we don't want a transient failure to replay a
  multi-thousand-post import wholesale — re-enqueue explicitly instead).
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query, only: [from: 2]
  require Logger

  alias Angler.Import.Instagram
  alias Angler.Repo
  alias Angler.Profiles.Profile

  @non_terminal ~w(available scheduled executing retryable)

  @doc """
  PubSub topic a LiveView can subscribe to for completion of `profile_id`'s
  import. The worker broadcasts `{:instagram_import_done, summary}` on success or
  `{:instagram_import_failed, reason}` on failure.
  """
  @spec topic(integer()) :: String.t()
  def topic(profile_id), do: "imports:instagram:#{profile_id}"

  @doc """
  Enqueue an import of `zip_path` into the profile with `profile_id`. `opts` are
  the same keyword options as `Angler.Import.Instagram.import_dir/3` (only the
  JSON-serialisable ones: `:visibility`, `:language`, `:dry_run`).
  """
  @spec enqueue(integer(), Path.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(profile_id, zip_path, opts \\ []) when is_integer(profile_id) do
    %{
      "profile_id" => profile_id,
      "zip_path" => zip_path,
      "opts" => Map.new(opts)
    }
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @doc """
  Whether `profile_id` already has an import queued or running. Lets the UI block
  concurrent imports for the same profile.
  """
  @spec pending?(integer()) :: boolean()
  def pending?(profile_id) when is_integer(profile_id) do
    Repo.exists?(
      from(j in Oban.Job,
        where:
          j.worker == "Angler.Import.Workers.InstagramImport" and
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
          case Instagram.import_zip(profile, zip_path, opts) do
            {:ok, summary} ->
              Logger.info("[instagram-import] profile #{profile_id}: #{inspect(summary)}")
              broadcast(profile_id, {:instagram_import_done, summary})
              :ok

            {:error, reason} ->
              broadcast(profile_id, {:instagram_import_failed, reason})
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

  # Only allow through the known, safe keys (Oban args arrive as string keys).
  defp decode_opts(map) when is_map(map) do
    [
      {:visibility, map["visibility"]},
      {:language, map["language"]},
      {:dry_run, map["dry_run"]}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end
end
