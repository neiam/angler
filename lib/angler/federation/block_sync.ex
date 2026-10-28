defmodule Angler.Federation.BlockSync do
  @moduledoc """
  FEP-070c block synchronization, as upstream v0.15's BlockSyncService.

  **Disclosing** (`disclose`, on by default). A peer learns which of its
  actors our users block, and only those: never another server's, and never
  to a banned, suspended or unlisted one (`disclosed_peer?/1`).

    * Blocking or unblocking a remote actor sends them `Block` / `Undo Block`
      (`Workers.BlockDeliver`).
    * Our deliveries carry a signed `Block-Synchronization: url="…/f/block_sync",
      digest="…"` header (`header/1`), the XOR of SHA-256(`"actor object"`)
      over those blocks.
    * `GET /f/block_sync`, signed by the peer, lists them with that digest
      as the ETag (`disclosed_pairs/1`); the instance actor advertises the
      endpoint as `blockSynchronization`.

  **Receiving** (`enabled`, on by default). A verified delivery whose signed
  header disagrees with the blocks of our users we hold from that server
  (`handle_inbound/2`) queues `Workers.BlockSync`, at most once per
  `cooldown` and not for six hours after a failed fetch. Every peer that has
  sent the header is also pulled daily (`Workers.BlockSyncReconcile`). A sync
  (`synchronize/4`) fetches their list signed as the instance actor, staying
  on their server, and:

    * applies blocks they list that we lack (at most 1000 a run, resolving
      at most 50 unknown actors);
    * removes blocks they don't list, but only from a complete,
      well-formed list that hashes to the digest it carries and names
      nothing we can't place, and never in a block's first ten minutes.

  `Block` and `Undo Block` arriving in an inbox (upstream HandlesBlocks) go
  through `apply_remote_block/2` and `remove_remote_block/2`.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Angler.Admin
  alias Angler.Federation.{Actor, Bans, HTTPSignature, Instance, Sync}
  alias Angler.Federation.Workers.BlockDeliver
  alias Angler.Federation.Workers.BlockSync, as: SyncWorker
  alias Angler.Profiles
  alias Angler.Profiles.{Block, BlocksMutes, Profile}
  alias Angler.Repo

  @header "block-synchronization"
  @context_term "https://w3id.org/fep/070c#blockSynchronization"
  @digest_term "https://w3id.org/fep/070c#blockSynchronizationDigest"
  @failure_backoff_s 21_600
  @removal_grace_s 600
  @max_items 50_000
  @max_apply_per_run 1000
  @max_new_actors_per_run 50

  ## Config

  @doc "Whether we act on peers' block lists (`AP_BLOCK_SYNC`)."
  def receiving?, do: config(:enabled, true) == true

  @doc "Whether we tell peers about our users' blocks (`AP_BLOCK_SYNC_DISCLOSE`)."
  def disclosing?, do: config(:disclose, true) == true

  @doc "Least seconds between header-driven syncs of one peer."
  def cooldown, do: max(60, config(:cooldown, 900))

  @doc "Most peers the daily reconcile queues."
  def reconcile_limit, do: max(1, config(:reconcile_limit, 1000))

  defp max_pages, do: max(1, config(:max_pages, 10))

  defp config(key, default),
    do: :angler |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)

  @doc "The header name, as sent."
  def header_name, do: "Block-Synchronization"

  @doc "Our block sync endpoint."
  def endpoint_url, do: AnglerWeb.Endpoint.url() <> "/f/block_sync"

  @doc "The FEP digest of `{actor, object}` block pairs."
  @spec digest([{String.t(), String.t()}]) :: String.t()
  def digest(pairs), do: pairs |> Enum.map(fn {a, o} -> a <> " " <> o end) |> Sync.digest()

  @doc "Parse a `Block-Synchronization` value."
  @spec parse_header(term()) :: {:ok, %{url: String.t(), digest: String.t()}} | :error
  def parse_header(value) when is_binary(value) do
    with {:ok, params} <- Sync.parse_params(String.trim(value)),
         url when is_binary(url) and url != "" <- params["url"],
         digest when is_binary(digest) <- Sync.normalize_digest(params["digest"]) do
      {:ok, %{url: url, digest: digest}}
    else
      _ -> :error
    end
  end

  def parse_header(_), do: :error

  @doc "An activity's actor or object id, given inline or as a string."
  def id_of(%{"id" => id}), do: id_of(id)
  def id_of(id) when is_binary(id) and id != "" and byte_size(id) <= 2048, do: id
  def id_of(_), do: nil

  @doc "Whether `authority` may hear about blocks of its actors."
  @spec disclosed_peer?(String.t()) :: boolean()
  def disclosed_peer?(authority) when is_binary(authority) do
    host = Sync.host(authority)

    authority != Sync.local_authority() and is_binary(host) and host != "" and
      not Bans.banned?(host) and not Admin.instance_suspended?(host) and
      not Repo.exists?(from i in Instance, where: i.domain == ^host and i.unlisted == true)
  end

  def disclosed_peer?(_), do: false

  ## Disclosing

  @doc "Our users' blocks of actors on `authority`, as sorted `{actor, object}` pairs."
  @spec disclosed_pairs(String.t()) :: [{String.t(), String.t()}]
  def disclosed_pairs(authority) do
    case Sync.host(authority) do
      host when is_binary(host) and host != "" ->
        from(b in Block,
          join: blocker in Profile,
          on: blocker.id == b.profile_id,
          join: blocked in Profile,
          on: blocked.id == b.target_id,
          where:
            is_nil(blocker.domain) and blocked.domain == ^host and
              not is_nil(blocked.remote_url),
          where: is_nil(blocker.status) or blocker.status != "deleted",
          where: is_nil(blocked.status) or blocked.status != "deleted",
          order_by: b.id,
          limit: @max_items,
          select: {blocker.username, blocked.remote_url}
        )
        |> Repo.all()
        |> Enum.filter(fn {_, object} -> Sync.authority(object) == authority end)
        |> Enum.map(fn {username, object} -> {local_actor_url(username), object} end)
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp local_actor_url(username), do: Profiles.actor_url(%Profile{username: username})

  @doc """
  The `Block-Synchronization` value for a delivery to `inbox_url`, or nil
  when we don't disclose to that server.
  """
  @spec header(String.t()) :: String.t() | nil
  def header(inbox_url) do
    with true <- disclosing?(),
         auth when is_binary(auth) <- Sync.authority(inbox_url),
         true <- disclosed_peer?(auth) do
      ~s(url="#{endpoint_url()}", digest="#{auth |> disclosed_pairs() |> digest()}")
    else
      _ -> nil
    end
  end

  @doc "`header/1` as a list of extra headers to sign."
  @spec headers(String.t()) :: [{String.t(), String.t()}]
  def headers(inbox_url) do
    case header(inbox_url) do
      nil -> []
      value -> [{header_name(), value}]
    end
  end

  @doc "Advertise the endpoint on the instance actor."
  @spec decorate_instance_actor(map()) :: map()
  def decorate_instance_actor(%{} = actor) do
    context = actor |> Map.get("@context", []) |> List.wrap()
    term = %{"blockSynchronization" => %{"@id" => @context_term, "@type" => "@id"}}

    actor
    |> Map.put("@context", context ++ [term])
    |> Map.put("blockSynchronization", endpoint_url())
  end

  @doc """
  A local profile blocked (`created?`) or unblocked a remote one: tell them,
  if we disclose to their server. Called from `BlocksMutes`.
  """
  @spec local_block_changed(Profile.t(), Profile.t(), integer(), boolean()) :: :ok
  def local_block_changed(
        %Profile{domain: nil} = blocker,
        %Profile{domain: d} = blocked,
        block_id,
        created?
      )
      when is_binary(d) do
    with true <- disclosing?(),
         true <- blocked.status != "deleted" and is_binary(blocked.inbox_url),
         auth when is_binary(auth) <- Sync.authority(blocked.remote_url),
         true <- disclosed_peer?(auth) do
      {:ok, _} = BlockDeliver.enqueue(blocker.id, blocked.id, block_id, not created?)
    end

    :ok
  end

  def local_block_changed(_, _, _, _), do: :ok

  ## Receiving

  defp received_query(host) do
    from(b in Block,
      join: blocker in Profile,
      on: blocker.id == b.profile_id,
      join: blocked in Profile,
      on: blocked.id == b.target_id,
      where:
        blocker.domain == ^host and not is_nil(blocker.remote_url) and is_nil(blocked.domain),
      where: is_nil(blocker.status) or blocker.status != "deleted",
      where: is_nil(blocked.status) or blocked.status != "deleted",
      select: %{
        id: b.id,
        blocker_id: b.profile_id,
        blocked_id: b.target_id,
        inserted_at: b.inserted_at,
        actor: blocker.remote_url,
        username: blocked.username
      }
    )
  end

  @doc "Blocks of our users we hold from actors on `authority`, keyed `{blocker_id, blocked_id}`."
  @spec received_blocks(String.t()) :: %{{integer(), integer()} => map()}
  def received_blocks(authority) do
    case Sync.host(authority) do
      host when is_binary(host) and host != "" ->
        host
        |> received_query()
        |> Repo.all()
        |> Enum.filter(&(Sync.authority(&1.actor) == authority))
        |> Map.new(fn row ->
          {{row.blocker_id, row.blocked_id}, Map.put(row, :object, local_actor_url(row.username))}
        end)

      _ ->
        %{}
    end
  end

  @doc "The digest of `received_blocks/1`."
  def received_digest(authority) do
    authority |> received_blocks() |> Map.values() |> Enum.map(&{&1.actor, &1.object}) |> digest()
  end

  @doc """
  Look at a verified delivery from `actor_url` and queue a sync if its
  signed `Block-Synchronization` disagrees with us. Never fails the delivery.
  """
  @spec handle_inbound(map(), String.t()) :: :ok
  def handle_inbound(headers, actor_url) when is_map(headers) and is_binary(actor_url) do
    with true <- receiving?(),
         raw when is_binary(raw) <- headers[@header],
         true <- @header in HTTPSignature.signed_header_names(Enum.into(headers, [])),
         {:ok, params} <- parse_header(raw),
         %Profile{domain: d, status: nil} = sender when is_binary(d) <-
           Repo.get_by(Profile, remote_url: actor_url),
         auth when is_binary(auth) <- Sync.authority(sender.remote_url),
         true <- auth != Sync.local_authority() and Sync.authority(params.url) == auth do
      remember_sync_url(auth, params.url)

      if params.digest != received_digest(auth) and not backed_off?(auth) do
        {:ok, _} = SyncWorker.enqueue(auth, params.url, params.digest)
      end

      :ok
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.debug("BlockSync: unusable header: #{Exception.message(e)}")
      :ok
  end

  def handle_inbound(_, _), do: :ok

  # The peer's endpoint, for the daily pull.
  defp remember_sync_url(authority, url) do
    if byte_size(url) <= 255 and Sync.authority(url) == authority do
      from(i in Instance,
        where:
          i.domain == ^Sync.host(authority) and
            (is_nil(i.block_sync_url) or i.block_sync_url != ^url)
      )
      |> Repo.update_all(set: [block_sync_url: url, updated_at: DateTime.utc_now()])
    end
  end

  defp backed_off?(authority) do
    now = DateTime.utc_now()

    Repo.exists?(
      from i in Instance,
        where: i.domain == ^Sync.host(authority) and i.block_sync_backoff_until > ^now
    )
  end

  @doc "Hold off header-driven syncs of `authority` after a failure."
  def back_off(authority) do
    until = DateTime.add(DateTime.utc_now(), @failure_backoff_s)

    from(i in Instance, where: i.domain == ^Sync.host(authority))
    |> Repo.update_all(set: [block_sync_backoff_until: until])

    :ok
  end

  @doc """
  Fetch `authority`'s block list from `url` and reconcile. `expected` is
  the digest they last signed, if any (a match skips the fetch); `deadline`
  a monotonic millisecond time to stop fetching by. Run from
  `Workers.BlockSync`.
  """
  @spec synchronize(String.t(), String.t(), String.t() | nil, integer() | nil) :: map()
  def synchronize(authority, url, expected \\ nil, deadline \\ nil) do
    result = %{status: :skipped, added: 0, removed: 0, unresolved: 0}
    normalized = Sync.normalize_digest(expected)
    host = Sync.host(authority)

    cond do
      not receiving?() or not is_binary(authority) or Sync.authority(authority) != authority or
        authority == Sync.local_authority() or Sync.authority(url) != authority or
          (expected != nil and normalized == nil) ->
        result

      Bans.banned?(host) or Admin.instance_suspended?(host) ->
        result

      normalized != nil and normalized == received_digest(authority) ->
        %{result | status: :in_sync}

      true ->
        case fetch_collection(url, authority, deadline) do
          nil -> %{result | status: :fetch_failed}
          collection -> reconcile(authority, collection, deadline, result)
        end
    end
  end

  defp reconcile(authority, collection, deadline, result) do
    %{items: items, complete: complete?, malformed: malformed?, digest: claimed} = collection

    # Removing blocks is destructive: only from a complete, well-formed list
    # that matches its own digest.
    can_remove? = complete? and not malformed? and claimed != nil and claimed == digest(items)

    {pairs, foreign?} =
      Enum.reduce(items, {[], false}, fn {actor, object}, {acc, foreign?} ->
        username = Sync.local_username(object)

        if Sync.authority(actor) == authority and username != nil,
          do: {[{actor, String.downcase(username)} | acc], foreign?},
          else: {acc, true}
      end)

    locals = resolve_locals(pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq())
    remotes = resolve_remotes(pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq(), deadline)

    {desired, unplaced?, unresolved} =
      pairs
      |> Enum.reverse()
      |> Enum.reduce({%{}, foreign?, 0}, fn {actor, name}, {desired, unplaced?, unresolved} ->
        case {locals[name], remotes[actor]} do
          {nil, _} ->
            {desired, true, unresolved}

          {_, nil} ->
            {desired, unplaced?, unresolved + 1}

          {local, remote} ->
            {Map.put(desired, {remote.id, local.id}, {remote, local}), unplaced?, unresolved}
        end
      end)

    can_remove? = can_remove? and not unplaced?
    known = received_blocks(authority)

    added =
      desired
      |> Enum.reject(fn {key, _} -> Map.has_key?(known, key) end)
      |> Enum.reduce_while(0, fn {_, {remote, local}}, n ->
        cond do
          n >= @max_apply_per_run -> {:halt, n}
          apply_remote_block(remote, local) -> {:cont, n + 1}
          true -> {:cont, n}
        end
      end)

    removed =
      if can_remove? do
        cutoff = DateTime.add(DateTime.utc_now(), -@removal_grace_s)

        known
        |> Enum.reject(fn {key, _} -> Map.has_key?(desired, key) end)
        |> Enum.filter(fn {_, row} -> DateTime.compare(row.inserted_at, cutoff) == :lt end)
        |> Enum.count(fn {_, row} -> remove_block_row(row) end)
      else
        0
      end

    result = %{
      result
      | status: if(can_remove?, do: :synchronized, else: :synchronized_without_removals),
        added: added,
        removed: removed,
        unresolved: unresolved
    }

    if added + removed > 0 do
      Logger.info("BlockSync: reconciled blocks from #{authority}: #{inspect(result)}")
    end

    result
  end

  # Lowercased username => local profile.
  defp resolve_locals([]), do: %{}

  defp resolve_locals(names) do
    from(p in Profile,
      where: is_nil(p.domain) and fragment("lower(?)", p.username) in ^names,
      where: is_nil(p.status) or p.status != "deleted"
    )
    |> Repo.all()
    |> Map.new(&{String.downcase(&1.username), &1})
  end

  # Actor id => remote profile, fetching at most a few unknown actors.
  defp resolve_remotes([], _deadline), do: %{}

  defp resolve_remotes(urls, deadline) do
    known =
      urls
      |> Enum.chunk_every(500)
      |> Enum.flat_map(fn chunk ->
        Repo.all(from p in Profile, where: not is_nil(p.domain) and p.remote_url in ^chunk)
      end)
      |> Map.new(&{&1.remote_url, &1})

    urls
    |> Enum.reject(&Map.has_key?(known, &1))
    |> Enum.reduce_while({known, 0}, fn url, {acc, fetched} ->
      if fetched >= @max_new_actors_per_run or past?(deadline) do
        {:halt, {acc, fetched}}
      else
        case Actor.resolve(url) do
          {:ok, %Profile{domain: d, remote_url: ^url} = p} when is_binary(d) ->
            {:cont, {Map.put(acc, url, p), fetched + 1}}

          _ ->
            {:cont, {acc, fetched + 1}}
        end
      end
    end)
    |> elem(0)
  end

  @doc """
  Fetch a possibly paged block list, signed as the instance actor, staying
  on `authority`: `%{items, complete, malformed, digest}` (`digest` being
  the one the collection carries), or nil when anything is off.
  """
  @spec fetch_collection(String.t(), String.t(), integer() | nil) :: map() | nil
  def fetch_collection(url, authority, deadline \\ nil) do
    with %{} = doc <- Sync.fetch_doc(url, authority),
         true <- Sync.collection?(doc) do
      acc = %{items: [], complete: true, malformed: false, digest: collection_digest(doc)}
      first = if Sync.items?(doc), do: doc, else: doc["first"]
      walk(first, authority, acc, MapSet.new([url]), 0, deadline)
    else
      _ -> nil
    end
  end

  defp walk(nil, _authority, acc, _seen, _pages, _deadline), do: acc

  defp walk(page_url, authority, acc, seen, pages, deadline) when is_binary(page_url) do
    cond do
      MapSet.member?(seen, page_url) ->
        nil

      pages + 1 > max_pages() or past?(deadline) ->
        %{acc | complete: false}

      true ->
        page_url
        |> Sync.fetch_doc(authority)
        |> walk(authority, acc, MapSet.put(seen, page_url), pages + 1, deadline)
    end
  end

  defp walk(%{} = page, authority, acc, seen, pages, deadline) do
    with true <- Sync.collection?(page),
         list when is_list(list) <- page_items(page["orderedItems"] || page["items"] || []),
         pairs = Enum.map(list, &item_to_pair/1),
         acc = %{
           acc
           | items: acc.items ++ Enum.reject(pairs, &is_nil/1),
             malformed: acc.malformed or nil in pairs
         },
         true <- length(acc.items) <= @max_items,
         next when is_nil(next) or is_binary(next) or is_map(next) <- page["next"] do
      walk(next, authority, acc, seen, pages, deadline)
    else
      _ -> nil
    end
  end

  defp walk(_, _, _, _, _, _), do: nil

  defp page_items(list) when is_list(list), do: list
  defp page_items(%{} = item), do: [item]
  defp page_items(_), do: nil

  defp item_to_pair(%{"type" => types} = item) do
    with true <- "Block" in List.wrap(types),
         actor when is_binary(actor) <- id_of(item["actor"]),
         object when is_binary(object) <- id_of(item["object"]) do
      {actor, object}
    else
      _ -> nil
    end
  end

  defp item_to_pair(_), do: nil

  defp collection_digest(doc),
    do: Sync.normalize_digest(doc["blockSynchronizationDigest"] || doc[@digest_term])

  defp past?(nil), do: false
  defp past?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  ## Applying

  @doc "Record a remote actor's block of a local one. True when it's new."
  @spec apply_remote_block(Profile.t(), Profile.t()) :: boolean()
  def apply_remote_block(%Profile{domain: d} = blocker, %Profile{domain: nil} = blocked)
      when is_binary(d) do
    blocker.id != blocked.id and not BlocksMutes.blocked?(blocker.id, blocked.id) and
      match?({:ok, _}, BlocksMutes.block(blocker, blocked))
  end

  def apply_remote_block(_, _), do: false

  @doc "Lift a remote actor's block of a local one. True when there was one."
  @spec remove_remote_block(Profile.t(), Profile.t()) :: boolean()
  def remove_remote_block(%Profile{domain: d} = blocker, %Profile{domain: nil} = blocked)
      when is_binary(d) do
    {n, _} =
      Repo.delete_all(
        from b in Block, where: b.profile_id == ^blocker.id and b.target_id == ^blocked.id
      )

    n > 0
  end

  def remove_remote_block(_, _), do: false

  defp remove_block_row(%{id: id, blocker_id: blocker_id, blocked_id: blocked_id}) do
    {n, _} =
      Repo.delete_all(
        from b in Block,
          where: b.id == ^id and b.profile_id == ^blocker_id and b.target_id == ^blocked_id
      )

    n > 0
  end
end
