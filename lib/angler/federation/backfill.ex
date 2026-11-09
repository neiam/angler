defmodule Angler.Federation.Backfill do
  @moduledoc """
  Pull a remote account's older public posts from its ActivityPub outbox.

  ActivityPub only pushes posts made while someone here follows the author,
  so a newly followed remote profile looks empty apart from whatever arrived
  since. An admin can ask for its history (`AnglerWeb.ProfileLive` →
  `Angler.Federation.Workers.Backfill`): we page through the author's outbox,
  newest first, and mirror each public `Create` through
  `Angler.Statuses.Federation.backfill/2`. That backdates each post to its
  `published` time and stays quiet: no home-feed fan-out, no mention
  notifications.

  Fetches are signed with the instance actor (servers with authorized fetch
  want that) and go through `Angler.Federation.HTTP`'s SSRF and
  banned-domain guards. The outbox, its pages and any object we have to
  dereference must live on the author's own host. Boosts (`Announce`) are
  skipped. Not every server publishes an outbox (some return an empty or
  totals-only collection); that just yields nothing.

  Besides the admin button, `after_follow/2` runs a backfill automatically
  the first time a local account follows a remote one (see `on_follow?/0`).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Angler.Federation.{Actor, HTTP, InstanceActor}
  alias Angler.Profiles.Profile
  alias Angler.Statuses.Federation, as: StatusFederation

  @default_limit 160
  @max_limit 500
  @max_pages 30

  @type result :: %{
          imported: non_neg_integer(),
          existing: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer()
        }

  def default_limit, do: @default_limit
  def max_limit, do: @max_limit

  @doc """
  Whether a remote account's history is fetched automatically the first time
  someone here follows it. On by default:

      config :angler, Angler.Federation.Backfill,
        on_follow: true,
        on_follow_limit: 160
  """
  @spec on_follow?() :: boolean()
  def on_follow?, do: config(:on_follow, true) == true

  @doc """
  Queue a backfill of `target` after `follower_id` (local) started following
  it, if `on_follow?/0` and nobody else here already follows it — their
  follow would have triggered one, and live delivery has kept it current
  since. Private accounts are skipped: their outbox holds nothing public.
  """
  @spec after_follow(Profile.t(), integer()) :: :ok
  def after_follow(%Profile{domain: domain, is_private: false} = target, follower_id)
      when is_binary(domain) do
    if on_follow?() and not other_local_followers?(target.id, follower_id) do
      limit = config(:on_follow_limit, @default_limit)
      {:ok, _} = Angler.Federation.Workers.Backfill.enqueue(target.id, limit)
    end

    :ok
  end

  def after_follow(_target, _follower_id), do: :ok

  defp other_local_followers?(target_id, follower_id) do
    Angler.Repo.exists?(
      from f in Angler.Follows.Follower,
        join: p in Profile,
        on: p.id == f.following_id and is_nil(p.domain),
        where: f.profile_id == ^target_id and f.following_id != ^follower_id
    )
  end

  defp config(key, default),
    do: :angler |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)

  @doc """
  Walk `profile`'s outbox until `limit` posts (default #{@default_limit},
  at most #{@max_limit}) have been imported, the outbox ends, or
  #{@max_pages} pages have been read.

  Returns `{:ok, result}` with counts of posts imported, already present,
  skipped (boosts, non-public, not authored by the account) and failed, or
  `{:error, reason}` when the outbox itself can't be read.
  """
  @spec run(Profile.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(profile, opts \\ [])

  def run(%Profile{domain: nil}, _opts), do: {:error, :local_profile}

  def run(%Profile{remote_url: actor_url} = profile, opts) when is_binary(actor_url) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit) |> max(1)
    signer = signer()

    with {:ok, outbox_url} <- outbox_url(profile),
         {:ok, collection} <- fetch(outbox_url, actor_url, signer) do
      acc = %{imported: 0, existing: 0, skipped: 0, failed: 0}
      {:ok, walk(collection, actor_url, signer, limit, @max_pages, acc)}
    end
  end

  def run(_, _), do: {:error, :no_actor}

  # Older cached profiles may predate storing `outbox_url`; refetch the actor.
  defp outbox_url(%Profile{outbox_url: url, remote_url: actor}) when is_binary(url) do
    if Actor.same_host?(url, actor), do: {:ok, url}, else: {:error, :foreign_outbox}
  end

  defp outbox_url(%Profile{remote_url: actor}) do
    case Actor.refresh(actor) do
      {:ok, %Profile{outbox_url: url} = p} when is_binary(url) -> outbox_url(p)
      {:ok, _} -> {:error, :no_outbox}
      {:error, _} = err -> err
    end
  end

  # A collection either inlines its items (small ones) or links `first`.
  defp walk(collection, actor, signer, limit, pages, acc) do
    case items(collection) do
      [] ->
        follow(collection["first"], actor, signer, limit, pages, acc)

      items ->
        acc = take(items, actor, signer, limit, acc)
        follow(collection["next"], actor, signer, limit, pages, acc)
    end
  end

  defp follow(_link, _actor, _signer, limit, _pages, %{imported: n} = acc) when n >= limit,
    do: acc

  defp follow(_link, _actor, _signer, _limit, 0, acc), do: acc

  defp follow(%{} = page, actor, signer, limit, pages, acc),
    do: walk_page(page, actor, signer, limit, pages, acc)

  defp follow(url, actor, signer, limit, pages, acc) when is_binary(url) do
    case fetch(url, actor, signer) do
      {:ok, page} ->
        walk_page(page, actor, signer, limit, pages, acc)

      {:error, reason} ->
        Logger.info("backfill: outbox page #{url} failed: #{inspect(reason)}")
        acc
    end
  end

  defp follow(_, _actor, _signer, _limit, _pages, acc), do: acc

  defp walk_page(page, actor, signer, limit, pages, acc) do
    acc = take(items(page), actor, signer, limit, acc)
    next = page["next"]

    # A page that links to itself (or nowhere) ends the walk.
    if is_binary(next) and next == page["id"],
      do: acc,
      else: follow(next, actor, signer, limit, pages - 1, acc)
  end

  defp items(%{"orderedItems" => items}) when is_list(items), do: items
  defp items(%{"items" => items}) when is_list(items), do: items
  defp items(_), do: []

  defp take(items, actor, signer, limit, acc) do
    Enum.reduce_while(items, acc, fn item, acc ->
      if acc.imported >= limit,
        do: {:halt, acc},
        else: {:cont, tally(acc, ingest(item, actor, signer))}
    end)
  end

  # Bare activity URI: dereference once, on the author's host.
  defp ingest(url, actor, signer) when is_binary(url) do
    case fetch(url, actor, signer) do
      {:ok, %{} = activity} -> ingest_activity(activity, actor, signer)
      _ -> :failed
    end
  end

  defp ingest(%{} = activity, actor, signer), do: ingest_activity(activity, actor, signer)
  defp ingest(_, _actor, _signer), do: :skipped

  defp ingest_activity(%{"type" => "Create", "object" => object} = activity, actor, signer) do
    if Actor.same_actor?(activity_actor(activity), actor),
      do: ingest_object(object, actor, signer),
      else: :skipped
  end

  # Some servers list bare objects rather than activities.
  defp ingest_activity(%{"type" => type} = object, actor, signer)
       when type in ["Note", "Question"],
       do: ingest_object(object, actor, signer)

  defp ingest_activity(_, _actor, _signer), do: :skipped

  defp ingest_object(url, actor, signer) when is_binary(url) do
    case fetch(url, actor, signer) do
      {:ok, %{"id" => id} = object} ->
        if Actor.same_actor?(id, url), do: ingest_object(object, actor, signer), else: :failed

      _ ->
        :failed
    end
  end

  defp ingest_object(%{} = object, actor, _signer) do
    case StatusFederation.backfill(object, actor) do
      :ok -> :imported
      {:error, :exists} -> :existing
      {:error, reason} when reason in [:not_public, :not_authored_by_actor] -> :skipped
      {:error, :unsupported_object_type} -> :skipped
      {:error, _} -> :failed
    end
  end

  defp ingest_object(_, _actor, _signer), do: :skipped

  defp activity_actor(%{"actor" => a}) when is_binary(a), do: a
  defp activity_actor(%{"actor" => %{"id" => a}}) when is_binary(a), do: a
  defp activity_actor(_), do: nil

  defp tally(acc, outcome), do: Map.update!(acc, outcome, &(&1 + 1))

  defp fetch(url, actor, signer) do
    if Actor.same_host?(url, actor),
      do: HTTP.fetch(url, signed_with: signer, max_bytes: 4 * 1024 * 1024),
      else: {:error, :foreign_host}
  end

  defp signer do
    actor = InstanceActor.ensure!()
    {actor.key_id, actor.private_key_pem}
  end
end
