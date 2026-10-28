defmodule Angler.Profiles.Workers.ActorUpdateDeliver do
  @moduledoc """
  Outbound `Update Person` delivery: when a local profile changes (avatar,
  header, display name, bio), sign and POST an AP `Update` activity to each
  remote follower's inbox so they refresh their cached copy.

  One job per `(profile, inbox)` — mirrors `StatusDeliver` — so retries are
  isolated. `enqueue_for/1` fans out over the profile's remote followers.

  `enqueue_for(profile, "delete")` sends `Delete Person` instead, when the
  account is deleted, so followers' servers drop it rather than keep a
  ghost (upstream 967ab88ec).
  """

  use Oban.Worker,
    queue: :federation_outbound,
    max_attempts: 8,
    unique: [period: 60, fields: [:args], keys: [:profile_id, :inbox_url]]

  import Ecto.Query, warn: false

  alias Angler.Federation.{ActorBuilder, Activity, BlockSync, HTTPSignature}
  alias Angler.Follows.Follower
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo

  @doc "Enqueue one Update (or Delete) delivery per remote follower inbox of `profile`."
  @spec enqueue_for(Profile.t(), String.t()) :: :ok
  def enqueue_for(profile, kind \\ "update")

  def enqueue_for(%Profile{domain: nil} = profile, kind) when kind in ["update", "delete"] do
    Enum.each(follower_inboxes(profile), &enqueue(profile.id, &1, kind))
    :ok
  end

  def enqueue_for(_, _), do: :ok

  @spec enqueue(integer(), String.t(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(profile_id, inbox_url, kind \\ "update")
      when is_integer(profile_id) and is_binary(inbox_url) do
    %{"profile_id" => profile_id, "inbox_url" => inbox_url, "kind" => kind}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id, "inbox_url" => inbox_url} = args}) do
    case Repo.get(Profile, profile_id) do
      %Profile{domain: nil} = profile -> deliver(profile, inbox_url, args["kind"] || "update")
      # Profile purged or somehow remote between enqueue and run.
      _ -> :ok
    end
  end

  defp follower_inboxes(%Profile{id: id}) do
    from(f in Follower,
      where: f.profile_id == ^id and not is_nil(f.accepted_at),
      join: p in Profile,
      on: p.id == f.following_id,
      where: not is_nil(p.domain),
      select: %{inbox: p.inbox_url, shared: p.shared_inbox_url}
    )
    |> Repo.all()
    |> Enum.map(fn %{inbox: i, shared: s} -> s || i end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp deliver(%Profile{} = profile, inbox_url, kind) do
    activity =
      if kind == "delete",
        do: ActorBuilder.delete_activity(profile),
        else: ActorBuilder.update_activity(profile)

    body = Jason.encode!(activity)
    uri = URI.parse(inbox_url)
    actor_url = Profiles.actor_url(profile)

    {:ok, headers} =
      HTTPSignature.sign(
        :post,
        uri.path || "/inbox",
        uri.host,
        body,
        actor_url <> "#main-key",
        profile.private_key_pem,
        [
          {"Content-Type", "application/activity+json"},
          {"Accept", "application/activity+json"}
        ] ++ BlockSync.headers(inbox_url)
      )

    case Angler.Federation.HTTP.deliver(
           [url: inbox_url, headers: headers, body: body, retry: false, receive_timeout: 10_000]
           |> Keyword.merge(req_overrides())
         ) do
      {:ok, %{status: code}} when code in 200..299 ->
        log(:delivered, activity["id"], actor_url, inbox_url, body)
        :ok

      {:ok, %{status: code}} when code in [410] or code in 400..499 ->
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

  defp log(status, activity_id, actor_url, inbox_url, body, error \\ nil) do
    Activity.changeset(%{
      direction: :outbound,
      activity_id: activity_id,
      activity_type: if(String.ends_with?(activity_id, "#delete"), do: "Delete", else: "Update"),
      actor_url: actor_url,
      target_inbox: inbox_url,
      raw_body: body,
      status: status,
      error: error,
      delivered_at: if(status == :delivered, do: DateTime.utc_now())
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  defp req_overrides, do: Application.get_env(:angler, :req_options, [])
end
