defmodule Angler.Likes.Federation do
  @moduledoc "Inbound `Like` and `Undo Like` handling."

  alias Angler.Federation.Actor
  alias Angler.Likes
  alias Angler.Notifications
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses
  alias Angler.Statuses.Status

  @doc "Insert a like and bump the parent status's likes_count."
  @spec handle_like(map(), String.t()) :: :ok | {:error, term()}
  def handle_like(%{"id" => activity_id, "object" => target_uri}, actor_url)
      when is_binary(activity_id) and is_binary(target_uri) do
    with {:ok, profile} <- Actor.resolve(actor_url),
         %Status{} = status <- Statuses.get_by_ap_id(target_uri),
         true <- Statuses.remote_interaction_allowed?(status, profile, :like) || :forbidden,
         {:ok, _like} <-
           Likes.insert(%{
             profile_id: profile.id,
             status_id: status.id,
             remote_url: activity_id
           }) do
      Statuses.inc_counter(status.id, :likes_count)

      Notifications.notify(%{
        recipient_id: status.profile_id,
        account_id: profile.id,
        type: "favourite",
        status_id: status.id
      })

      :ok
    else
      nil -> {:error, :unknown_target}
      :forbidden -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_like(_, _), do: {:error, :bad_like_payload}

  @doc "Remove a previously-recorded like."
  @spec handle_undo_like(map(), String.t()) :: :ok | {:error, term()}
  def handle_undo_like(%{"object" => %{"type" => "Like", "id" => like_uri}}, actor_url)
      when is_binary(like_uri) do
    case Likes.get_by_remote_url(like_uri) do
      nil ->
        :ok

      like ->
        undo_owned_like(like, actor_url)
    end
  end

  def handle_undo_like(_, _), do: {:error, :bad_undo_like_payload}

  # Only the actor who liked can take the like back.
  defp undo_owned_like(like, actor_url) do
    with %Profile{remote_url: owner} <- Repo.get(Profile, like.profile_id),
         true <- Actor.same_actor?(owner, actor_url),
         n when n > 0 <- Likes.delete(like.profile_id, like.status_id) do
      Statuses.inc_counter(like.status_id, :likes_count, -1)
    end

    :ok
  end
end
