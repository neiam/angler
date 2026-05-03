defmodule Angler.Follows.Federation do
  @moduledoc """
  Inbound activity handlers for the Follow lifecycle.

  Each function takes the parsed activity payload + the verified actor URL.
  Returns `:ok | {:error, reason}`. The caller (ActivityHandler worker) maps
  errors to Oban retry/discard.
  """

  alias Angler.Federation.Actor
  alias Angler.Federation.Workers.FollowDeliver
  alias Angler.Follows
  alias Angler.Profiles
  alias Angler.Profiles.Profile

  @doc """
  Handle inbound `Follow` — record the edge, schedule outbound `Accept`.

  Locked-target case is recorded as a follow_request and waits for explicit
  acceptance via the (future) accounts grouping endpoint.
  """
  @spec handle_follow(map(), String.t()) :: :ok | {:error, atom()}
  def handle_follow(%{"id" => activity_id, "object" => target_url}, actor_url)
      when is_binary(activity_id) and is_binary(target_url) do
    with {:ok, %Profile{domain: nil} = followee} <- resolve_local_target(target_url),
         {:ok, follower} <- Actor.resolve(actor_url) do
      case Follows.insert_inbound_follow(followee.id, follower.id, remote_url: activity_id) do
        {:ok, :accepted, _row} ->
          FollowDeliver.enqueue(:accept, %{
            local_actor_id: followee.id,
            inbox_url: follower.inbox_url,
            follow_activity_id: activity_id,
            follow_actor_url: actor_url
          })

          :ok

        {:ok, :pending, _row} ->
          # No outbound Accept yet — waits for the followee to authorize.
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, _remote_target} -> {:error, :not_local_target}
      :error -> {:error, :unknown_target}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_follow(_, _), do: {:error, :bad_follow_payload}

  @doc "Handle inbound `Undo Follow`."
  @spec handle_undo_follow(map(), String.t()) :: :ok | {:error, atom()}
  def handle_undo_follow(%{"object" => %{"object" => target_url}}, actor_url)
      when is_binary(target_url) do
    with {:ok, followee} <- resolve_local_target(target_url),
         {:ok, follower} <- Actor.resolve(actor_url) do
      Follows.remove_inbound_follow(followee.id, follower.id)
      :ok
    else
      _ -> {:error, :bad_undo_payload}
    end
  end

  def handle_undo_follow(_, _), do: {:error, :bad_undo_payload}

  ## Internals

  defp resolve_local_target(target_url) when is_binary(target_url) do
    base = AnglerWeb.Endpoint.url()

    case String.split(target_url, base <> "/users/", parts: 2) do
      [_, username] ->
        case Profiles.get_local_by_username(username) do
          %Profile{} = p -> {:ok, p}
          nil -> :error
        end

      _ ->
        :error
    end
  end
end
