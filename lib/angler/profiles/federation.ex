defmodule Angler.Profiles.Federation do
  @moduledoc """
  Inbound activity handlers for profile-affecting verbs:
  `Update Person`, `Delete Person`.
  """

  alias Angler.Federation.Actor
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

        :ok
    end
  end
end
