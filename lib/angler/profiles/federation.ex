defmodule Angler.Profiles.Federation do
  @moduledoc """
  Inbound activity handlers for profile-affecting verbs:
  `Update Person`, `Delete Person`, `Block`, `Undo Block`.
  """

  alias Angler.Federation.Actor
  alias Angler.Profiles
  alias Angler.Profiles.{BlocksMutes, Profile}
  alias Angler.Repo

  @doc """
  Refresh a cached remote profile from an `Update Person` activity.

  We trust the activity carries the new state inline (Mastodon does this);
  if it doesn't, we re-fetch the actor doc.
  """
  @spec handle_update(map(), String.t()) :: :ok | {:error, atom()}
  def handle_update(%{"object" => %{"id" => actor_url}}, actor_url) do
    case Actor.refresh(actor_url) do
      {:ok, _profile} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_update(_, _), do: {:error, :bad_update_payload}

  @doc """
  Soft-delete a cached remote profile in response to a `Delete Person`.

  The full purge (statuses, follows, media) is enqueued to a dedicated
  cleanup worker, but doesn't exist yet — for now we mark the row deleted
  so it's hidden from public surfaces.
  """
  @spec handle_delete_person(String.t()) :: :ok
  def handle_delete_person(actor_url) when is_binary(actor_url) do
    case Repo.get_by(Profile, remote_url: actor_url) do
      nil ->
        :ok

      profile ->
        profile
        |> Profile.changeset(%{status: "deleted"})
        |> Repo.update!()

        Angler.Quotes.actor_deleted(profile.id)
    end
  end

  @doc """
  A remote actor blocked a local one (upstream 39532e8ba): record the block,
  which also drops follows both ways, so their posts stop reaching each
  other here. Mastodon sends this when a user blocks someone on another
  server.
  """
  @spec handle_block(map(), String.t()) :: :ok | {:error, atom()}
  def handle_block(%{"object" => target_url}, actor_url) when is_binary(target_url) do
    with {:ok, target} <- local_target(target_url),
         {:ok, blocker} <- Actor.resolve(actor_url),
         {:ok, _} <- BlocksMutes.block(blocker, target) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unknown_target}
    end
  end

  def handle_block(_, _), do: {:error, :bad_block_payload}

  @spec handle_undo_block(map(), String.t()) :: :ok | {:error, atom()}
  def handle_undo_block(%{"object" => %{"object" => target_url}}, actor_url)
      when is_binary(target_url) do
    with {:ok, target} <- local_target(target_url),
         %Profile{} = blocker <- Repo.get_by(Profile, remote_url: actor_url) do
      BlocksMutes.unblock(blocker, target)
    else
      _ -> :ok
    end
  end

  def handle_undo_block(_, _), do: {:error, :bad_undo_block_payload}

  defp local_target(url) do
    case String.split(url, AnglerWeb.Endpoint.url() <> "/users/", parts: 2) do
      ["", username] ->
        case Profiles.get_local_by_username(username) do
          %Profile{} = p -> {:ok, p}
          nil -> :error
        end

      _ ->
        :error
    end
  end
end
