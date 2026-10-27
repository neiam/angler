defmodule Angler.Reblogs.Federation do
  @moduledoc "Inbound `Announce` (reblog) and `Undo Announce` handling."

  alias Angler.Federation.Actor
  alias Angler.Notifications
  alias Angler.Profiles.Profile
  alias Angler.Reblogs
  alias Angler.Repo
  alias Angler.Statuses
  alias Angler.Statuses.Status

  @spec handle_announce(map(), String.t()) :: :ok | {:error, term()}
  def handle_announce(%{"id" => activity_id, "object" => target_uri}, actor_url)
      when is_binary(activity_id) and is_binary(target_uri) do
    with {:ok, profile} <- Actor.resolve(actor_url),
         %Status{} = status <- find_local_status(target_uri),
         true <- Statuses.remote_interaction_allowed?(status, profile, :announce) || :forbidden,
         {:ok, _reblog} <-
           Reblogs.insert(%{
             profile_id: profile.id,
             status_id: status.id,
             remote_url: activity_id
           }) do
      Statuses.inc_counter(status.id, :reblogs_count)
      Angler.Timelines.Workers.FeedInsert.enqueue_reblog(status.id, profile.id)

      Notifications.notify(%{
        recipient_id: status.profile_id,
        account_id: profile.id,
        type: "reblog",
        status_id: status.id
      })

      :ok
    else
      nil -> {:error, :unknown_target}
      :forbidden -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_announce(_, _), do: {:error, :bad_announce_payload}

  @spec handle_undo_announce(map(), String.t()) :: :ok | {:error, term()}
  def handle_undo_announce(
        %{"object" => %{"type" => "Announce", "id" => announce_uri}},
        actor_url
      )
      when is_binary(announce_uri) do
    case Reblogs.get_by_remote_url(announce_uri) do
      nil -> :ok
      reblog -> undo_owned_reblog(reblog, actor_url)
    end
  end

  def handle_undo_announce(_, _), do: {:error, :bad_undo_announce_payload}

  # Only the actor who boosted can take the boost back.
  defp undo_owned_reblog(reblog, actor_url) do
    with %Profile{remote_url: owner} <- Repo.get(Profile, reblog.profile_id),
         true <- Actor.same_actor?(owner, actor_url),
         n when n > 0 <- Reblogs.delete(reblog.profile_id, reblog.status_id) do
      Statuses.inc_counter(reblog.status_id, :reblogs_count, -1)
    end

    :ok
  end

  defp find_local_status(uri) do
    Statuses.get_by_uri(uri) || find_by_local_url(uri)
  end

  defp find_by_local_url(url) do
    base = AnglerWeb.Endpoint.url() <> "/p/"

    case String.split(url, base, parts: 2) do
      [_, rest] ->
        case String.split(rest, "/") do
          [_username, id_str] ->
            case Integer.parse(id_str) do
              {id, ""} -> Statuses.get(id)
              _ -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end
end
