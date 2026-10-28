defmodule Angler.Stories.Workers.StoryDeliver do
  @moduledoc """
  Delivers one story activity from a local account to one remote inbox
  (upstream StoryPipeline StoryFanout / StoryDelete / StoryExpire fan-out,
  StoryViewDeliver, StoryReactionDeliver, StoryReplyDeliver). Built by
  `Angler.Stories.Outbound`.

  The activity is built up front and carried in the job, so a `Delete`
  still goes out after the story row is gone. Follower fan-outs (`"sync"`)
  carry the FEP-8fcf and FEP-070c sync headers, as `StatusDeliver` does.
  """

  use Oban.Worker,
    queue: :federation_outbound,
    max_attempts: 5,
    unique: [period: 60, fields: [:args]]

  alias Angler.Federation.{Activity, BlockSync, FollowersSync, HTTP, HTTPSignature}
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo

  @spec enqueue(integer(), String.t(), map(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(from_id, inbox_url, activity, opts \\ []) do
    %{
      "from_id" => from_id,
      "inbox_url" => inbox_url,
      "activity" => activity,
      "sync" => Keyword.get(opts, :sync, false)
    }
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"from_id" => from_id, "inbox_url" => inbox, "activity" => act} = args
      }) do
    case Repo.get(Profile, from_id) do
      %Profile{domain: nil, private_key_pem: pem} = from when is_binary(pem) ->
        deliver(from, inbox, act, args["sync"] == true)

      _ ->
        :ok
    end
  end

  defp deliver(%Profile{} = from, inbox_url, activity, sync?) do
    body = Jason.encode!(activity)
    uri = URI.parse(inbox_url)
    actor_url = Profiles.actor_url(from)

    extra = if sync?, do: sync_header(from, inbox_url) ++ BlockSync.headers(inbox_url), else: []

    {:ok, headers} =
      HTTPSignature.sign(
        :post,
        uri.path || "/inbox",
        uri.host,
        body,
        actor_url <> "#main-key",
        from.private_key_pem,
        [
          {"Content-Type", "application/activity+json"},
          {"Accept", "application/activity+json"}
        ] ++ extra
      )

    result =
      HTTP.deliver(
        [url: inbox_url, headers: headers, body: body, retry: false, receive_timeout: 10_000]
        |> Keyword.merge(Application.get_env(:angler, :req_options, []))
      )

    {status, error, ret} =
      case result do
        {:ok, %{status: code}} when code in 200..299 ->
          {:delivered, nil, :ok}

        {:ok, %{status: code}} when code in 400..499 ->
          {:rejected, "remote #{code}", :ok}

        {:ok, %{status: code}} ->
          {:error, "remote #{code}", {:error, "remote #{code}"}}

        {:error, :host_unavailable} ->
          {:rejected, "host unavailable", {:cancel, :host_unavailable}}

        {:error, reason} ->
          {:error, inspect(reason), {:error, reason}}
      end

    Activity.changeset(%{
      direction: :outbound,
      activity_id: activity["id"],
      activity_type: activity["type"],
      actor_url: actor_url,
      target_inbox: inbox_url,
      raw_body: body,
      status: status,
      error: error,
      delivered_at: if(status == :delivered, do: DateTime.utc_now())
    })
    |> Repo.insert(on_conflict: :nothing)

    ret
  end

  defp sync_header(actor, inbox_url) do
    case FollowersSync.header(actor, inbox_url) do
      nil -> []
      value -> [{FollowersSync.header_name(), value}]
    end
  end
end
