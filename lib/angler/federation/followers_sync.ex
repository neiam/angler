defmodule Angler.Federation.FollowersSync do
  @moduledoc """
  FEP-8fcf followers collection synchronization, as upstream v0.15's
  FollowersSyncService.

  **Sending.** Deliveries of a local actor's posts carry a signed
  `Collection-Synchronization` header: the XOR of the SHA-256 of every
  follower id on the receiving server (`header/2`). That server compares it
  with its own idea of who follows us there and, if they disagree, fetches
  `/users/:username/followers_synchronization` (signed) for the list
  (`partial_followers/2`).

  **Receiving.** A delivery from a remote actor with that header signed
  (`handle_inbound/2`) is checked against the local profiles we think follow
  them; on a mismatch `Workers.FollowersSync` fetches their list and
  reconciles (`synchronize/4`):

    * a local follow they don't list is dropped, but only when the list is
      complete and hashes to the digest they signed, and never in its first
      ten minutes (an Accept may still be in flight);
    * a pending follow they list is accepted;
    * a listed local profile that doesn't follow them gets an `Undo Follow`
      sent for it (at most 100 a run).

  Actor ids are compared by "authority" (scheme, host and a non-default
  port), as the FEP defines the partial collection.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Angler.Federation.{HTTPSignature, Sync}
  alias Angler.Federation.Workers.FollowersSync, as: SyncWorker
  alias Angler.Follows
  alias Angler.Follows.Follower
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo

  @header "collection-synchronization"
  @removal_grace_s 600
  @max_items 100_000
  @max_undo_per_run 100
  @max_pages 10

  @doc "The header name, as sent."
  def header_name, do: "Collection-Synchronization"

  @doc "See `Angler.Federation.Sync.authority/1`."
  defdelegate authority(url), to: Sync

  @doc "See `Angler.Federation.Sync.digest/1`."
  defdelegate digest(ids), to: Sync

  defp local_authority, do: Sync.local_authority()

  ## Sending

  @doc """
  The `Collection-Synchronization` value for delivering `profile`'s activity
  to `inbox_url`, or nil when it isn't one of ours going elsewhere.
  """
  @spec header(Profile.t(), String.t()) :: String.t() | nil
  def header(%Profile{domain: nil} = profile, inbox_url) do
    case authority(inbox_url) do
      nil ->
        nil

      auth ->
        if auth == local_authority() do
          nil
        else
          actor_url = Profiles.actor_url(profile)

          digest =
            case partial_followers(profile, auth) do
              [] -> Sync.empty_digest()
              ids -> digest(ids)
            end

          ~s(collectionId="#{actor_url}/followers", url="#{actor_url}/followers_synchronization", digest="#{digest}")
        end
    end
  end

  def header(_, _), do: nil

  @doc "`profile`'s followers whose actor ids are on `authority`, sorted."
  @spec partial_followers(Profile.t(), String.t()) :: [String.t()]
  def partial_followers(%Profile{domain: nil, id: pid}, authority) when is_binary(authority) do
    host = URI.parse(authority).host

    from(f in Follower,
      join: p in Profile,
      on: p.id == f.following_id,
      where:
        f.profile_id == ^pid and not is_nil(f.accepted_at) and p.domain == ^host and
          not is_nil(p.remote_url) and is_nil(p.status),
      distinct: true,
      select: p.remote_url
    )
    |> Repo.all()
    |> Enum.filter(&(authority(&1) == authority))
    |> Enum.sort()
  end

  def partial_followers(_, _), do: []

  ## Receiving

  @doc """
  Look at a verified delivery from `actor_url` and queue a synchronization
  if its signed `Collection-Synchronization` disagrees with us. Never fails
  the delivery.
  """
  @spec handle_inbound(map(), String.t()) :: :ok
  def handle_inbound(headers, actor_url) when is_map(headers) and is_binary(actor_url) do
    with raw when is_binary(raw) <- headers[@header],
         true <- @header in HTTPSignature.signed_header_names(Enum.into(headers, [])),
         {:ok, params} <- parse_header(raw),
         %Profile{domain: d, status: nil} = sender when is_binary(d) <-
           Repo.get_by(Profile, remote_url: actor_url),
         true <- sender_matches?(sender, params.collection_id, params.url),
         true <- sender.followers_url == params.collection_id,
         false <- params.digest == local_follower_digest(sender) do
      SyncWorker.enqueue(sender.id, params.collection_id, params.url, params.digest)
      :ok
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.debug("FollowersSync: unusable header: #{Exception.message(e)}")
      :ok
  end

  def handle_inbound(_, _), do: :ok

  @doc "Parse a header value (`signature`-style `k=\"v\"` pairs)."
  @spec parse_header(String.t()) ::
          {:ok, %{collection_id: String.t(), url: String.t(), digest: String.t()}} | :error
  def parse_header(value) do
    with {:ok, params} <- Sync.parse_params(value),
         digest when is_binary(digest) <- Sync.normalize_digest(params["digest"]),
         true <- params["collectionId"] not in [nil, ""] and params["url"] not in [nil, ""] do
      {:ok, %{collection_id: params["collectionId"], url: params["url"], digest: digest}}
    else
      _ -> :error
    end
  end

  # The collection and its sync URL must be on the sender's own authority,
  # so nobody can have us fetch a third party's followers.
  defp sender_matches?(%Profile{remote_url: remote}, collection_id, url) do
    auth = authority(remote)

    auth != nil and auth != local_authority() and authority(collection_id) == auth and
      authority(url) == auth
  end

  # Local profiles that follow `remote`, per our database.
  defp local_followers(%Profile{id: rid}) do
    Repo.all(
      from f in Follower,
        join: p in Profile,
        on: p.id == f.following_id,
        where: f.profile_id == ^rid and not is_nil(f.accepted_at) and is_nil(p.domain),
        select: {p, f.inserted_at}
    )
  end

  defp local_follower_digest(remote) do
    remote |> local_followers() |> Enum.map(fn {p, _} -> Profiles.actor_url(p) end) |> digest()
  end

  @doc """
  Fetch `sender`'s partial followers collection for us and reconcile. Run
  from `Workers.FollowersSync`.
  """
  @spec synchronize(Profile.t(), String.t(), String.t(), String.t()) :: map()
  def synchronize(%Profile{} = sender, collection_id, url, expected) do
    result = %{status: :skipped, removed: 0, accepted: 0, undone: 0}
    expected = String.downcase(expected)

    cond do
      unusable_request?(sender, collection_id, url, expected) ->
        result

      sender.followers_url != collection_id ->
        %{result | status: :collection_mismatch}

      expected == local_follower_digest(sender) ->
        %{result | status: :in_sync}

      true ->
        case fetch_collection(url, authority(sender.remote_url)) do
          nil -> %{result | status: :fetch_failed}
          collection -> reconcile(sender, collection, expected, result)
        end
    end
  end

  # Not one we'll act on: a local or gone sender, a malformed digest, or
  # urls that aren't the sender's.
  defp unusable_request?(sender, collection_id, url, expected) do
    is_nil(sender.domain) or not is_nil(sender.status) or
      not Regex.match?(~r/\A[0-9a-f]{64}\z/, expected) or
      not sender_matches?(sender, collection_id, url)
  end

  defp reconcile(sender, %{items: items, complete: complete?}, expected, result) do
    items = Enum.uniq(items)
    segments = Enum.map(items, &Sync.local_username/1)

    # Removing follows is destructive: only from a complete list that hashes
    # to what they signed and holds nothing we can't read as a local actor.
    can_remove? = complete? and digest(items) == expected and nil not in segments

    listed = listed_locals(segments)
    known = local_followers(sender)
    known_ids = MapSet.new(known, fn {p, _} -> p.id end)

    stale = if can_remove?, do: stale_followers(known, listed), else: []

    Enum.each(stale, fn p -> :ok = Follows.remove_inbound_follow(sender.id, p.id) end)
    removed = length(stale)

    {accepted, undone} =
      listed
      |> Enum.reject(&MapSet.member?(known_ids, &1.id))
      |> settle_unknown(sender)

    result = %{
      result
      | status: if(can_remove?, do: :synchronized, else: :synchronized_without_removals),
        removed: removed,
        accepted: accepted,
        undone: undone
    }

    if removed + accepted + undone > 0 do
      Logger.info("FollowersSync: reconciled #{sender.remote_url}: #{inspect(result)}")
    end

    result
  end

  defp listed_locals(segments) do
    case Enum.reject(segments, &is_nil/1) do
      [] -> []
      names -> Repo.all(from p in Profile, where: is_nil(p.domain) and p.username in ^names)
    end
  end

  # Known followers they no longer list, past the grace period.
  defp stale_followers(known, listed) do
    listed_ids = MapSet.new(listed, & &1.id)
    cutoff = DateTime.add(DateTime.utc_now(), -@removal_grace_s)

    for {p, at} <- known,
        not MapSet.member?(listed_ids, p.id),
        DateTime.compare(at, cutoff) == :lt,
        do: p
  end

  # Listed locals we don't know as followers: accept a pending follow, or
  # undo (up to the per-run cap). `{accepted, undone}`.
  defp settle_unknown(locals, sender) do
    Enum.reduce(locals, {0, 0}, fn local, {acc, und} ->
      case Follows.get_follower(sender.id, local.id) do
        %Follower{accepted_at: nil, remote_url: follow_id} when is_binary(follow_id) ->
          {:ok, _} = Follows.accept_remote!(follow_id)
          {acc + 1, und}

        _ when und < @max_undo_per_run ->
          send_undo(local, sender)
          {acc, und + 1}

        _ ->
          {acc, und}
      end
    end)
  end

  # They list a local profile that doesn't follow them here.
  defp send_undo(%Profile{status: nil, private_key_pem: pem} = local, sender)
       when is_binary(pem) do
    Angler.Federation.Workers.FollowDeliver.enqueue(:undo, %{
      local_actor_id: local.id,
      inbox_url: sender.shared_inbox_url || sender.inbox_url,
      follow_activity_id: nil,
      target_actor_url: sender.remote_url
    })
  end

  defp send_undo(_, _), do: :ok

  @doc """
  Fetch a possibly paged collection, signed as the instance actor, staying
  on `authority`. `%{items, complete}`, or nil when anything is off (a
  failed fetch is never an empty list).
  """
  @spec fetch_collection(String.t(), String.t()) ::
          %{items: [String.t()], complete: boolean()} | nil
  def fetch_collection(url, authority) do
    with %{} = doc <- Sync.fetch_doc(url, authority),
         true <- Sync.collection?(doc) do
      first = if Sync.items?(doc), do: doc, else: doc["first"]
      walk(first, authority, [], MapSet.new([url]), 0)
    else
      _ -> nil
    end
  end

  defp walk(nil, _authority, items, _seen, _pages), do: %{items: items, complete: true}

  defp walk(page_url, authority, items, seen, pages) when is_binary(page_url) do
    cond do
      MapSet.member?(seen, page_url) ->
        nil

      pages + 1 > @max_pages ->
        %{items: items, complete: false}

      true ->
        walk(
          Sync.fetch_doc(page_url, authority),
          authority,
          items,
          MapSet.put(seen, page_url),
          pages + 1
        )
    end
  end

  defp walk(%{} = page, authority, items, seen, pages) do
    with true <- Sync.collection?(page),
         {:ok, page_items} <- page_items(page["orderedItems"] || page["items"] || []),
         items = items ++ page_items,
         true <- length(items) <= @max_items,
         next when is_nil(next) or is_binary(next) or is_map(next) <- page["next"] do
      walk(next, authority, items, seen, pages)
    else
      _ -> nil
    end
  end

  defp walk(_, _, _, _, _), do: nil

  defp page_items(item) when is_binary(item) or is_map(item), do: page_items([item])

  defp page_items(list) when is_list(list) do
    ids =
      Enum.map(list, fn
        %{"id" => id} when is_binary(id) and id != "" -> id
        id when is_binary(id) and id != "" -> id
        _ -> nil
      end)

    if nil in ids, do: :error, else: {:ok, ids}
  end

  defp page_items(_), do: :error
end
