defmodule Angler.Statuses.Workers.InteractionDeliver do
  @moduledoc """
  Outbound deliverer for status interactions: `Like`, `Undo Like`, `Announce`,
  `Undo Announce`. One job per `(verb, activity_id, inbox_url)`.

  Triggered when a local user favourites / reblogs (and their inverses) a
  status whose author is **remote**. Local-author interactions stay local —
  no outbound activity to send.
  """

  use Oban.Worker,
    queue: :federation_outbound,
    max_attempts: 8,
    unique: [period: 60, fields: [:args], keys: [:verb, :activity_id, :inbox_url]]

  alias Angler.Federation.Activity
  alias Angler.Federation.HTTPSignature
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo

  @doc """
  Enqueue an outbound interaction.

  `verb` is one of `:like`, `:undo_like`, `:announce`, `:undo_announce`.
  Required args:

    * `local_actor_id` — id of the local profile performing the action
    * `inbox_url` — target inbox (typically the status author's inbox)
    * `activity_id` — for like/announce, the URL we mint up front; for the
      undo variants, the URL of the original Like/Announce we're undoing
    * `target_uri` — the AS2 id of the status being acted on (for like /
      announce only — undo wraps the activity_id)
  """
  @spec enqueue(atom(), map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(verb, args)
      when verb in [:like, :undo_like, :announce, :undo_announce] and is_map(args) do
    %{"verb" => Atom.to_string(verb)}
    |> Map.merge(stringify_keys(args))
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"verb" => verb} = args}) do
    actor = Repo.get!(Profile, args["local_actor_id"])
    body = build(verb, actor, args) |> Jason.encode!()
    deliver(actor, args["inbox_url"], body, args["activity_id"], activity_type(verb))
  end

  ## Activity builders

  defp build("like", %Profile{} = actor, %{"activity_id" => id, "target_uri" => uri}) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => id,
      "type" => "Like",
      "actor" => Profiles.actor_url(actor),
      "object" => uri
    }
  end

  defp build("announce", %Profile{} = actor, %{"activity_id" => id, "target_uri" => uri}) do
    actor_url = Profiles.actor_url(actor)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => id,
      "type" => "Announce",
      "actor" => actor_url,
      # Mastodon convention: address Public + the author's followers and the
      # author themselves so the boost reaches their watchers.
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [actor_url <> "/followers"],
      "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "object" => uri
    }
  end

  defp build("undo_like", %Profile{} = actor, %{
         "activity_id" => undo_id,
         "original_id" => original_id,
         "target_uri" => uri
       }) do
    actor_url = Profiles.actor_url(actor)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => undo_id,
      "type" => "Undo",
      "actor" => actor_url,
      "object" => %{
        "id" => original_id,
        "type" => "Like",
        "actor" => actor_url,
        "object" => uri
      }
    }
  end

  defp build("undo_announce", %Profile{} = actor, %{
         "activity_id" => undo_id,
         "original_id" => original_id,
         "target_uri" => uri
       }) do
    actor_url = Profiles.actor_url(actor)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => undo_id,
      "type" => "Undo",
      "actor" => actor_url,
      "object" => %{
        "id" => original_id,
        "type" => "Announce",
        "actor" => actor_url,
        "object" => uri
      }
    }
  end

  ## Sign + POST

  defp deliver(%Profile{} = actor, inbox_url, body, activity_id, activity_type) do
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
        log(:delivered, activity_id, activity_type, actor_url, inbox_url, body)
        :ok

      {:ok, %{status: 410}} ->
        log(:rejected, activity_id, activity_type, actor_url, inbox_url, body, "remote 410 gone")
        :ok

      {:ok, %{status: code}} when code in 400..499 ->
        log(:rejected, activity_id, activity_type, actor_url, inbox_url, body, "remote #{code}")
        :ok

      {:ok, %{status: code}} ->
        log(:error, activity_id, activity_type, actor_url, inbox_url, body, "remote #{code}")
        {:error, "remote #{code}"}

      {:error, :host_unavailable} ->
        {:cancel, :host_unavailable}

      {:error, reason} ->
        log(:error, activity_id, activity_type, actor_url, inbox_url, body, inspect(reason))
        {:error, reason}
    end
  end

  defp log(status, activity_id, activity_type, actor_url, inbox_url, body, error \\ nil) do
    Activity.changeset(%{
      direction: :outbound,
      activity_id: activity_id,
      activity_type: activity_type,
      actor_url: actor_url,
      target_inbox: inbox_url,
      raw_body: body,
      status: status,
      error: error,
      delivered_at: if(status == :delivered, do: DateTime.utc_now())
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  defp activity_type("like"), do: "Like"
  defp activity_type("announce"), do: "Announce"
  defp activity_type("undo_like"), do: "Undo"
  defp activity_type("undo_announce"), do: "Undo"

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp req_overrides do
    Application.get_env(:angler, :req_options, [])
  end
end
