defmodule Angler.Quotes.Workers.QuoteDeliver do
  @moduledoc """
  Delivers a consent answer from a local author to one remote actor: the
  `Accept` or `Reject` of a `QuoteRequest` or `FeatureRequest`, or the
  `Delete` revoking a quote or feature stamp (`Angler.FeaturedCollections`).

  The activity is built up front and carried in the job, so it still goes
  out after the quoted post is deleted. Retries on temporary failures: the
  quoting server sends its request once, so a lost Accept would leave the
  quote pending there for good.
  """

  use Oban.Worker,
    queue: :federation_outbound,
    max_attempts: 8,
    unique: [period: 60, fields: [:args]]

  alias Angler.Federation.{Activity, HTTP, HTTPSignature}
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo

  @spec enqueue(integer(), integer(), map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(from_id, to_id, activity) do
    %{"from_id" => from_id, "to_id" => to_id, "activity" => activity}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"from_id" => from_id, "to_id" => to_id, "activity" => activity}}) do
    with %Profile{private_key_pem: pem} = from when is_binary(pem) <- Repo.get(Profile, from_id),
         %Profile{} = to <- Repo.get(Profile, to_id),
         inbox when is_binary(inbox) <- to.inbox_url || to.shared_inbox_url do
      deliver(from, inbox, activity)
    else
      # Author or quoter gone, or nowhere to send it.
      _ -> :ok
    end
  end

  defp deliver(%Profile{} = from, inbox_url, activity) do
    body = Jason.encode!(activity)
    uri = URI.parse(inbox_url)
    actor_url = Profiles.actor_url(from)

    {:ok, headers} =
      HTTPSignature.sign(
        :post,
        uri.path || "/inbox",
        uri.host,
        body,
        actor_url <> "#main-key",
        from.private_key_pem,
        [{"Content-Type", "application/activity+json"}, {"Accept", "application/activity+json"}]
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
end
