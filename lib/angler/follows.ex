defmodule Angler.Follows do
  @moduledoc """
  Follow edges between profiles.

  This module is the single canonical place follow / unfollow state changes
  happen. Both directions land here:

  * **Inbound** (a remote actor follows / unfollows / accepts) — called by
    `Angler.Follows.Federation` from the federation worker chain.
  * **Local-initiated** (`POST /accounts/:id/follow`) — called by the
    Mastodon API controller. Local-target follows are accepted immediately
    (or queued as `follow_request` if the target is locked); remote-target
    follows insert a `pending_remote: true` row and enqueue an outbound
    `Follow` activity.

  Counter housekeeping (`profiles.followers_count` / `following_count`)
  happens **only** when a row transitions to accepted — `accept!/2`,
  `accept_remote!/1`, and the local-unlocked path of both `follow/3` and
  `insert_inbound_follow/3`.
  """

  import Ecto.Query, warn: false

  alias Angler.Federation.Workers.FollowDeliver
  alias Angler.Follows.{FollowRequest, Follower}
  alias Angler.Notifications
  alias Angler.Profiles.Profile
  alias Angler.Repo

  ## Reads

  @doc "Get a follower row by `(profile_id = followee, following_id = follower)`."
  @spec get_follower(integer(), integer()) :: Follower.t() | nil
  def get_follower(profile_id, following_id) do
    Repo.get_by(Follower, profile_id: profile_id, following_id: following_id)
  end

  @doc "Get a follow_request by `(profile_id = followee, following_id = follower)`."
  @spec get_request(integer(), integer()) :: FollowRequest.t() | nil
  def get_request(profile_id, following_id) do
    Repo.get_by(FollowRequest, profile_id: profile_id, following_id: following_id)
  end

  @doc """
  Accounts that follow `profile` (most recent first). Only accepted edges —
  pending remote follows are excluded, matching `followers_count`.
  """
  @spec list_followers(Profile.t(), keyword()) :: [Profile.t()]
  def list_followers(%Profile{id: id}, opts \\ []) do
    Repo.all(
      from f in Follower,
        join: p in Profile,
        on: p.id == f.following_id,
        where: f.profile_id == ^id and f.pending_remote == false,
        order_by: [desc: f.id],
        limit: ^Keyword.get(opts, :limit, 40),
        select: p
    )
  end

  @doc """
  Accounts that `profile` follows (most recent first). Only accepted edges,
  matching `following_count`.
  """
  @spec list_following(Profile.t(), keyword()) :: [Profile.t()]
  def list_following(%Profile{id: id}, opts \\ []) do
    Repo.all(
      from f in Follower,
        join: p in Profile,
        on: p.id == f.profile_id,
        where: f.following_id == ^id and f.pending_remote == false,
        order_by: [desc: f.id],
        limit: ^Keyword.get(opts, :limit, 40),
        select: p
    )
  end

  ## Local-initiated follow

  @doc """
  `actor` follows `target`.

  * Local target, unlocked → `{:ok, :accepted, follower}`, counters bumped.
  * Local target, locked → `{:ok, :pending, follow_request}`.
  * Remote target → `{:ok, :pending_remote, follower}`, outbound `Follow`
    enqueued. The `Follower` row's `remote_url` is the activity id we
    just signed; inbound `Accept Follow` matches on it to flip accepted.

  Idempotent. Repeat calls return the existing row.
  """
  @spec follow(Profile.t(), Profile.t()) ::
          {:ok, :accepted, Follower.t()}
          | {:ok, :pending, FollowRequest.t()}
          | {:ok, :pending_remote, Follower.t()}
          | {:error, atom() | Ecto.Changeset.t()}
  def follow(%Profile{} = actor, %Profile{} = target) do
    cond do
      actor.id == target.id ->
        {:error, :self_follow}

      is_nil(actor.domain) and is_nil(target.domain) ->
        local_follow(actor, target)

      is_nil(actor.domain) and not is_nil(target.domain) ->
        remote_follow(actor, target)

      true ->
        # actor must be local — only local users can initiate via the API.
        {:error, :not_local_actor}
    end
  end

  defp local_follow(%Profile{} = actor, %Profile{} = target) do
    case get_follower(target.id, actor.id) do
      %Follower{} = existing ->
        {:ok, :accepted, existing}

      nil ->
        case get_request(target.id, actor.id) do
          %FollowRequest{} = existing ->
            {:ok, :pending, existing}

          nil ->
            if target.is_private,
              do: insert_request(target, actor),
              else: insert_accepted(target, actor, nil)
        end
    end
  end

  defp insert_request(target, actor) do
    %{profile_id: target.id, following_id: actor.id}
    |> FollowRequest.changeset()
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:profile_id, :following_id])
    |> case do
      {:ok, %FollowRequest{id: nil}} ->
        {:ok, :pending, get_request(target.id, actor.id)}

      {:ok, fr} ->
        Notifications.notify(%{
          recipient_id: target.id,
          account_id: actor.id,
          type: "follow_request"
        })

        {:ok, :pending, fr}

      err ->
        err
    end
  end

  defp insert_accepted(target, actor, remote_url) do
    Repo.transaction(fn ->
      result =
        %{
          profile_id: target.id,
          following_id: actor.id,
          remote_url: remote_url,
          accepted_at: DateTime.utc_now()
        }
        |> Follower.changeset()
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:profile_id, :following_id])

      case result do
        {:ok, %Follower{id: nil}} ->
          # Race; row already there. Don't bump counters.
          get_follower(target.id, actor.id)

        {:ok, follower} ->
          inc_counters!(follower.profile_id, :followers_count, 1)
          inc_counters!(follower.following_id, :following_count, 1)
          follower

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, follower} ->
        Notifications.notify(%{
          recipient_id: follower.profile_id,
          account_id: follower.following_id,
          type: "follow"
        })

        {:ok, :accepted, follower}

      err ->
        err
    end
  end

  defp remote_follow(%Profile{} = actor, %Profile{} = target) do
    case get_follower(target.id, actor.id) do
      %Follower{} = existing when not is_nil(existing.accepted_at) ->
        {:ok, :accepted, existing}

      %Follower{} = existing ->
        {:ok, :pending_remote, existing}

      nil ->
        # Mint the outbound activity id up front so the inbound Accept can
        # find this row by `remote_url`.
        nonce = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

        activity_id =
          AnglerWeb.Endpoint.url() <> "/users/" <> actor.username <> "/follows/" <> nonce

        result =
          %{
            profile_id: target.id,
            following_id: actor.id,
            remote_url: activity_id,
            pending_remote: true
          }
          |> Follower.changeset()
          |> Repo.insert(on_conflict: :nothing, conflict_target: [:profile_id, :following_id])

        case result do
          {:ok, follower} ->
            FollowDeliver.enqueue(:follow, %{
              local_actor_id: actor.id,
              inbox_url: target.shared_inbox_url || target.inbox_url,
              follow_activity_id: activity_id,
              target_actor_url: target.remote_url
            })

            {:ok, :pending_remote, follower}

          err ->
            err
        end
    end
  end

  ## Unfollow

  @doc """
  `actor` unfollows `target`.

  Removes any `Follower` and `FollowRequest` rows. If the target is remote,
  enqueues an outbound `Undo Follow`. Decrements counters when an accepted
  follower row was removed. Idempotent (safe to call when no edge exists).
  """
  @spec unfollow(Profile.t(), Profile.t()) :: :ok
  def unfollow(%Profile{} = actor, %Profile{} = target) do
    follower = get_follower(target.id, actor.id)
    request = get_request(target.id, actor.id)

    Repo.transaction(fn ->
      if follower do
        Repo.delete!(follower)

        if follower.accepted_at do
          inc_counters!(target.id, :followers_count, -1)
          inc_counters!(actor.id, :following_count, -1)
        end
      end

      if request, do: Repo.delete!(request)
      :ok
    end)

    if not is_nil(target.domain) and follower do
      FollowDeliver.enqueue(:undo, %{
        local_actor_id: actor.id,
        inbox_url: target.shared_inbox_url || target.inbox_url,
        follow_activity_id: follower.remote_url,
        target_actor_url: target.remote_url
      })
    end

    :ok
  end

  ## Inbound

  @doc """
  Insert a follow edge for an inbound `Follow` activity.

  Locked target → `follow_request`. Unlocked → accepted Follower with
  counter bumps.
  """
  @spec insert_inbound_follow(integer(), integer(), keyword()) ::
          {:ok, :accepted, Follower.t()}
          | {:ok, :pending, FollowRequest.t()}
          | {:error, atom() | Ecto.Changeset.t()}
  def insert_inbound_follow(followee_id, follower_id, opts \\ []) do
    if followee_id == follower_id do
      {:error, :self_follow}
    else
      remote_url = Keyword.get(opts, :remote_url)
      followee = Repo.get!(Profile, followee_id)
      follower = Repo.get!(Profile, follower_id)

      if followee.is_private do
        insert_request(followee, follower)
        |> with_request_remote_url(remote_url, followee_id, follower_id)
      else
        insert_accepted(followee, follower, remote_url)
      end
    end
  end

  defp with_request_remote_url({:ok, :pending, _} = result, nil, _, _), do: result

  defp with_request_remote_url({:ok, :pending, fr}, remote_url, _, _) do
    updated = fr |> Ecto.Changeset.change(remote_url: remote_url) |> Repo.update!()
    {:ok, :pending, updated}
  end

  defp with_request_remote_url(other, _, _, _), do: other

  @doc """
  Accept a previously-pending outbound `Follow` we sent to a remote actor.

  Called by `ActivityHandler` on inbound `Accept Follow` whose `object.id`
  matches the row's `remote_url`. Idempotent — already-accepted rows are
  returned without further counter bumps.
  """
  @spec accept_remote!(String.t()) :: {:ok, Follower.t()} | {:error, :not_found}
  def accept_remote!(activity_id) when is_binary(activity_id) do
    case Repo.get_by(Follower, remote_url: activity_id) do
      nil ->
        {:error, :not_found}

      %Follower{accepted_at: %DateTime{}} = follower ->
        {:ok, follower}

      %Follower{} = follower ->
        {:ok, accepted} =
          follower
          |> Ecto.Changeset.change(
            accepted_at: DateTime.utc_now(),
            pending_remote: false
          )
          |> Repo.update()

        inc_counters!(follower.profile_id, :followers_count, 1)
        inc_counters!(follower.following_id, :following_count, 1)
        {:ok, accepted}
    end
  end

  @doc "Remove a follow edge (inbound `Undo Follow`). Idempotent. Decrements counters."
  @spec remove_inbound_follow(integer(), integer()) :: :ok
  def remove_inbound_follow(followee_id, follower_id) do
    case get_follower(followee_id, follower_id) do
      nil ->
        :ok

      follower ->
        Repo.delete!(follower)

        if follower.accepted_at do
          inc_counters!(followee_id, :followers_count, -1)
          inc_counters!(follower_id, :following_count, -1)
        end
    end

    Repo.delete_all(
      from r in FollowRequest,
        where: r.profile_id == ^followee_id and r.following_id == ^follower_id
    )

    :ok
  end

  ## Follow requests (authorize / reject — locked-account flow)

  @doc """
  List follow requests pending against `target_id`. Newest first.
  """
  @spec list_requests(integer(), pos_integer()) :: [
          %{request: FollowRequest.t(), follower: Profile.t()}
        ]
  def list_requests(target_id, limit \\ 40) do
    Repo.all(
      from r in FollowRequest,
        join: p in Profile,
        on: p.id == r.following_id,
        where: r.profile_id == ^target_id and is_nil(p.status),
        order_by: [desc: r.id],
        limit: ^limit,
        select: %{request: r, follower: p}
    )
  end

  @doc """
  Authorize a follow request from `follower` against `target`. Promotes the
  pending row into an accepted `Follower`, bumps counters, generates a
  "follow" notification, and — if the follower is remote — enqueues an
  outbound `Accept Follow`.
  """
  @spec authorize_request(Profile.t(), Profile.t()) ::
          {:ok, Follower.t()} | {:error, :not_found}
  def authorize_request(%Profile{} = target, %Profile{} = follower) do
    case get_request(target.id, follower.id) do
      nil ->
        {:error, :not_found}

      %FollowRequest{} = request ->
        result =
          Repo.transaction(fn ->
            Repo.delete!(request)

            {:ok, follower_row} =
              %{
                profile_id: target.id,
                following_id: follower.id,
                remote_url: request.remote_url,
                accepted_at: DateTime.utc_now()
              }
              |> Follower.changeset()
              |> Repo.insert(on_conflict: :nothing, conflict_target: [:profile_id, :following_id])

            row = follower_row || get_follower(target.id, follower.id)

            inc_counters!(target.id, :followers_count, 1)
            inc_counters!(follower.id, :following_count, 1)

            row
          end)

        case result do
          {:ok, %Follower{} = row} ->
            Notifications.notify(%{
              recipient_id: target.id,
              account_id: follower.id,
              type: "follow"
            })

            if not is_nil(follower.domain) and is_binary(request.remote_url) do
              FollowDeliver.enqueue(:accept, %{
                local_actor_id: target.id,
                inbox_url: follower.shared_inbox_url || follower.inbox_url,
                follow_activity_id: request.remote_url,
                follow_actor_url: follower.remote_url
              })
            end

            {:ok, row}

          err ->
            err
        end
    end
  end

  @doc """
  Reject a follow request from `follower` against `target`. Idempotent. For
  remote followers we additionally enqueue an outbound `Reject Follow`.
  """
  @spec reject_request(Profile.t(), Profile.t()) :: :ok
  def reject_request(%Profile{} = target, %Profile{} = follower) do
    case get_request(target.id, follower.id) do
      nil ->
        :ok

      %FollowRequest{} = request ->
        Repo.delete!(request)

        if not is_nil(follower.domain) and is_binary(request.remote_url) do
          FollowDeliver.enqueue(:reject, %{
            local_actor_id: target.id,
            inbox_url: follower.shared_inbox_url || follower.inbox_url,
            follow_activity_id: request.remote_url,
            follow_actor_url: follower.remote_url
          })
        end

        :ok
    end
  end

  ## Counter helper

  defp inc_counters!(profile_id, field, by)
       when field in [:followers_count, :following_count] and is_integer(by) do
    Repo.update_all(
      from(p in Profile, where: p.id == ^profile_id),
      inc: [{field, by}]
    )

    :ok
  end
end
