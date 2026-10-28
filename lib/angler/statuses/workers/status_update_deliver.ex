defmodule Angler.Statuses.Workers.StatusUpdateDeliver do
  @moduledoc "Outbound `Update Note` delivery for an edited local status."

  use Oban.Worker,
    queue: :federation_outbound,
    max_attempts: 8,
    unique: [period: 60, fields: [:args], keys: [:status_id, :inbox_url]]

  alias Angler.Federation.Activity
  alias Angler.Federation.HTTPSignature
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses.{OutboundAudience, Status}

  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  @spec enqueue_for(Status.t()) :: :ok
  def enqueue_for(%Status{} = status) do
    Enum.each(OutboundAudience.inboxes_for(status), fn inbox_url ->
      %{"status_id" => status.id, "inbox_url" => inbox_url}
      |> __MODULE__.new()
      |> Oban.insert()
    end)

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"status_id" => status_id, "inbox_url" => inbox_url}}) do
    case Repo.get(Status, status_id) do
      nil -> :ok
      %Status{deleted_at: %DateTime{}} -> :ok
      %Status{} = status -> deliver(Repo.get!(Profile, status.profile_id), status, inbox_url)
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
        [{"Content-Type", "application/activity+json"}, {"Accept", "application/activity+json"}]
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
    {to, cc} = audience_uris(actor_url, status)

    update_id =
      (status.uri || status.url) <>
        "/update/" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1",
        Angler.Quotes.note_context_terms()
      ],
      "id" => update_id,
      "type" => "Update",
      "actor" => actor_url,
      "to" => to,
      "cc" => cc,
      "object" => %{
        "id" => status.uri || status.url,
        "type" => "Note",
        "attributedTo" => actor_url,
        "content" => status.rendered || "",
        "summary" => status.cw_summary,
        "sensitive" => status.is_nsfw,
        "updated" => DateTime.to_iso8601(status.edited_at || DateTime.utc_now()),
        "to" => to,
        "cc" => cc,
        "interactionPolicy" => Angler.Quotes.interaction_policy(status, actor)
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
      activity_type: "Update",
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
