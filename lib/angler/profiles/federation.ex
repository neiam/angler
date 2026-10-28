defmodule Angler.Profiles.Federation do
  @moduledoc """
  Inbound activity handlers for profile-affecting verbs:
  `Update Person`, `Delete Person`, `Block`, `Undo Block`.
  """

  alias Angler.Federation.{Actor, BlockSync, Sync}
  alias Angler.Profiles
  alias Angler.Profiles.Profile
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
  A remote actor blocked a local one (upstream 39532e8ba, HandlesBlocks):
  record the block, which also drops follows both ways, so their posts stop
  reaching each other here. Mastodon sends this when a user blocks someone
  on another server. Ignored when block sync receiving is off (FEP-070c,
  `Angler.Federation.BlockSync`). The inbox has already checked the
  signature is the actor's own.
  """
  @spec handle_block(map(), String.t()) :: :ok | {:error, atom()}
  def handle_block(%{} = activity, actor_url) do
    with true <- BlockSync.receiving?() || :disabled,
         ^actor_url <- BlockSync.id_of(activity["actor"]) || actor_url,
         object when is_binary(object) <- BlockSync.id_of(activity["object"]),
         {:ok, target} <- local_target(object),
         {:ok, %Profile{domain: d} = blocker} when is_binary(d) <- Actor.resolve(actor_url) do
      BlockSync.apply_remote_block(blocker, target)
      :ok
    else
      :disabled -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unknown_target}
    end
  end

  def handle_block(_, _), do: {:error, :bad_block_payload}

  @spec handle_undo_block(map(), String.t()) :: :ok | {:error, atom()}
  def handle_undo_block(%{"object" => %{} = block}, actor_url) do
    with true <- BlockSync.receiving?(),
         true <- BlockSync.id_of(block["actor"]) in [nil, actor_url],
         object when is_binary(object) <- BlockSync.id_of(block["object"]),
         {:ok, target} <- local_target(object),
         %Profile{domain: d} = blocker when is_binary(d) <-
           Repo.get_by(Profile, remote_url: actor_url) do
      BlockSync.remove_remote_block(blocker, target)
      :ok
    else
      _ -> :ok
    end
  end

  def handle_undo_block(_, _), do: {:error, :bad_undo_block_payload}

  defp local_target(url) do
    with name when is_binary(name) <- Sync.local_username(url),
         %Profile{} = p <- Profiles.get_local_by_username(name) do
      {:ok, p}
    else
      _ -> :error
    end
  end
end
