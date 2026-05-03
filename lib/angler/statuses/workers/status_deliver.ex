defmodule Angler.Statuses.Workers.StatusDeliver do
  @moduledoc """
  Outbound `Create Note` delivery: sign and POST the AS2 activity to a
  single remote inbox.

  Pattern matches `Angler.Federation.Workers.FollowDeliver` — one job per
  `(status, inbox)` so retries are isolated.

  Triggered by a per-status fan-out helper (`enqueue_for/1`) which computes
  the audience via `OutboundAudience` and inserts one job per inbox.

  See plans/federation/queues/status_activity_pub_deliver.md.
  """

  use Oban.Worker,
    queue: :federation_outbound,
    max_attempts: 8,
    unique: [period: 60, fields: [:args], keys: [:status_id, :inbox_url]]

  import Ecto.Query, warn: false
  require Logger

  alias Angler.Federation.Activity
  alias Angler.Federation.HTTPSignature
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses.{OutboundAudience, Status}

  @doc "Enqueue one delivery per remote inbox in `status`'s audience."
  @spec enqueue_for(Status.t()) :: :ok
  def enqueue_for(%Status{} = status) do
    Enum.each(OutboundAudience.inboxes_for(status), fn inbox_url ->
      enqueue(status.id, inbox_url)
    end)

    :ok
  end

  @spec enqueue(integer(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(status_id, inbox_url)
      when is_integer(status_id) and is_binary(inbox_url) do
    %{"status_id" => status_id, "inbox_url" => inbox_url}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"status_id" => status_id, "inbox_url" => inbox_url}}) do
    case Repo.get(Status, status_id) do
      nil ->
        # Status was hard-deleted between enqueue and run.
        :ok

      %Status{deleted_at: %DateTime{}} ->
        :ok

      status ->
        actor = Repo.get!(Profile, status.profile_id)
        deliver(actor, status, inbox_url)
    end
  end

  ## Build + sign + POST

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

    case Req.post(
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
    {to, cc} = audience_uris(actor_url, status)

    object =
      %{
        "id" => status.uri || status.url,
        "type" => "Note",
        "attributedTo" => actor_url,
        "content" => status.rendered || "",
        "published" => DateTime.to_iso8601(status.inserted_at || DateTime.utc_now()),
        "url" => status.url || status.uri,
        "to" => to,
        "cc" => cc,
        "sensitive" => status.is_nsfw,
        "summary" => status.cw_summary,
        "tag" => render_tag_array(status),
        "attachment" => []
      }
      |> drop_nils()

    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1"
      ],
      "id" => (status.uri || status.url) <> "/activity",
      "type" => "Create",
      "actor" => actor_url,
      "published" => object["published"],
      "to" => to,
      "cc" => cc,
      "object" => object
    }
  end

  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  defp audience_uris(actor_url, %Status{visibility: :public}) do
    {[@public_uri], [actor_url <> "/followers"]}
  end

  defp audience_uris(actor_url, %Status{visibility: :unlisted}) do
    {[actor_url <> "/followers"], [@public_uri]}
  end

  defp audience_uris(actor_url, %Status{visibility: :private}) do
    {[actor_url <> "/followers"], []}
  end

  defp audience_uris(_actor_url, %Status{visibility: :direct, id: status_id}) do
    # Direct: address mentioned profiles' actor URLs explicitly.
    mention_urls =
      from(m in Angler.Statuses.Mention,
        where: m.status_id == ^status_id,
        join: p in Angler.Profiles.Profile,
        on: p.id == m.profile_id,
        select: p.remote_url
      )
      |> Repo.all()
      |> Enum.reject(&is_nil/1)

    {mention_urls, []}
  end

  # AS2 `tag` array: emit Mention + Hashtag entries that match what we
  # parse on the inbound side, so a round-trip through ourselves works.
  defp render_tag_array(%Status{} = status) do
    status = Repo.preload(status, [:mentions, status_hashtags: :hashtag])

    mentions =
      Enum.map(status.mentions, fn m ->
        profile = Repo.get!(Profile, m.profile_id)

        %{
          "type" => "Mention",
          "name" =>
            "@" <> profile.username <> if(profile.domain, do: "@" <> profile.domain, else: ""),
          "href" => Profiles.actor_url(profile)
        }
      end)

    hashtags =
      Enum.map(status.status_hashtags, fn sh ->
        %{
          "type" => "Hashtag",
          "name" => "#" <> sh.hashtag.name,
          "href" => AnglerWeb.Endpoint.url() <> "/tags/" <> sh.hashtag.name
        }
      end)

    mentions ++ hashtags
  end

  defp drop_nils(map) do
    Map.reject(map, fn {_, v} -> is_nil(v) end)
  end

  defp log(status, activity_id, actor_url, inbox_url, body, error \\ nil) do
    Activity.changeset(%{
      direction: :outbound,
      activity_id: activity_id,
      activity_type: "Create",
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
