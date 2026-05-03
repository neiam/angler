defmodule Angler.Likes.Federation do
  @moduledoc "Inbound `Like` and `Undo Like` handling."

  alias Angler.Federation.Actor
  alias Angler.Likes
  alias Angler.Notifications
  alias Angler.Statuses
  alias Angler.Statuses.Status

  @doc "Insert a like and bump the parent status's likes_count."
  @spec handle_like(map(), String.t()) :: :ok | {:error, term()}
  def handle_like(%{"id" => activity_id, "object" => target_uri}, actor_url)
      when is_binary(activity_id) and is_binary(target_uri) do
    with {:ok, profile} <- Actor.resolve(actor_url),
         %Status{} = status <- find_local_status(target_uri),
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
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_like(_, _), do: {:error, :bad_like_payload}

  @doc "Remove a previously-recorded like."
  @spec handle_undo_like(map(), String.t()) :: :ok | {:error, term()}
  def handle_undo_like(%{"object" => %{"type" => "Like", "id" => like_uri}}, _actor_url)
      when is_binary(like_uri) do
    case Likes.get_by_remote_url(like_uri) do
      nil ->
        :ok

      like ->
        case Likes.delete(like.profile_id, like.status_id) do
          n when n > 0 ->
            Statuses.inc_counter(like.status_id, :likes_count, -1)
            :ok

          _ ->
            :ok
        end
    end
  end

  def handle_undo_like(_, _), do: {:error, :bad_undo_like_payload}

  defp find_local_status(uri) do
    Statuses.get_by_uri(uri) || find_by_local_url(uri)
  end

  # Local statuses are referenced by their canonical URL form
  # (`<base>/p/<username>/<id>`), not by `uri` (which is null for local).
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
