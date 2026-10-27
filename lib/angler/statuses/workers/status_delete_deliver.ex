defmodule Angler.Statuses.Workers.StatusDeleteDeliver do
  @moduledoc """
  Outbound `Delete Tombstone` delivery for a soft-deleted local status.

  Pattern matches `StatusDeliver` — one job per `(status, inbox)` so retries
  isolate per-recipient. The status row is expected to be soft-deleted
  before this fires; we read it back to grab the actor + uri, but we don't
  need any of the mutable fields.
  """

  use Oban.Worker,
    queue: :federation_outbound,
    max_attempts: 8,
    unique: [period: 60, fields: [:args], keys: [:status_id, :inbox_url]]

  alias Angler.Federation.Activity
  alias Angler.Federation.HTTPSignature
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses.Status

  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  @spec enqueue(integer(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(status_id, inbox_url) do
    %{"status_id" => status_id, "inbox_url" => inbox_url}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"status_id" => status_id, "inbox_url" => inbox_url}}) do
    case Repo.get(Status, status_id) do
      nil ->
        :ok

      status ->
        actor = Repo.get!(Profile, status.profile_id)
        deliver(actor, status, inbox_url)
    end
  end

  defp deliver(%Profile{} = actor, %Status{} = status, inbox_url) do
    activity = build_activity(actor, status)
    body = Jason.encode!(activity)
    uri = URI.parse(inbox_url)
    actor_url = Profiles.actor_url(actor)

    {:ok, headers} =
      HTTPSignature.sign(
        :post,
        uri.path || "/inbox",
        uri.host,
        body,
        actor_url <> "#main-key",
        actor.private_key_pem,
        [
          {"Content-Type", "application/activity+json"},
          {"Accept", "application/activity+json"}
        ]
      )

    case Angler.Federation.HTTP.deliver(
           [
             url: inbox_url,
             headers: headers,
             body: body,
             retry: false,
             receive_timeout: 10_000
           ]
           |> Keyword.merge(req_overrides())
         ) do
      {:ok, %{status: code}} when code in 200..299 ->
        log(:delivered, activity["id"], actor_url, inbox_url, body)
        :ok

      {:ok, %{status: 410}} ->
        log(:rejected, activity["id"], actor_url, inbox_url, body, "remote 410 gone")
        :ok

      {:ok, %{status: code}} when code in 400..499 ->
        log(:rejected, activity["id"], actor_url, inbox_url, body, "remote #{code}")
        :ok

      {:ok, %{status: code}} ->
        log(:error, activity["id"], actor_url, inbox_url, body, "remote #{code}")
        {:error, "remote #{code}"}

      {:error, reason} ->
        log(:error, activity["id"], actor_url, inbox_url, body, inspect(reason))
        {:error, reason}
    end
  end

  defp build_activity(%Profile{} = actor, %Status{} = status) do
    actor_url = Profiles.actor_url(actor)
    object_uri = status.uri || status.url

    delete_id =
      object_uri <>
        "/delete/" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    {to, cc} = audience_uris(actor_url, status)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => delete_id,
      "type" => "Delete",
      "actor" => actor_url,
      "to" => to,
      "cc" => cc,
      "object" => %{
        "id" => object_uri,
        "type" => "Tombstone"
      }
    }
  end

  defp audience_uris(actor_url, %Status{visibility: v}) when v in [:public, :unlisted] do
    {[@public_uri], [actor_url <> "/followers"]}
  end

  defp audience_uris(actor_url, %Status{visibility: :private}) do
    {[actor_url <> "/followers"], []}
  end

  defp audience_uris(_actor_url, %Status{visibility: :direct}), do: {[], []}

  defp log(status, activity_id, actor_url, inbox_url, body, error \\ nil) do
    Activity.changeset(%{
      direction: :outbound,
      activity_id: activity_id,
      activity_type: "Delete",
      actor_url: actor_url,
      target_inbox: inbox_url,
      raw_body: body,
      status: status,
      error: error,
      delivered_at: if(status == :delivered, do: DateTime.utc_now())
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  defp req_overrides do
    Application.get_env(:angler, :req_options, [])
  end
end
