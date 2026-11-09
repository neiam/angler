defmodule Angler.Federation.Instances do
  @moduledoc """
  Read-side queries over known peer instances for the admin servers page
  (`AnglerWeb.AdminInstancesLive`).

  An `instances` row exists for every domain we have fetched an actor from or
  tried to deliver to, which is the "known servers" count on the landing
  page. Here each row is joined with what we hold locally about that domain:
  known accounts, follow edges in both directions, and statuses received.
  """

  import Ecto.Query, warn: false

  alias Angler.Federation.Instance
  alias Angler.Follows.Follower
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses.Status

  @page_size 50

  @filters ~w(all failing unreachable banned limited)
  @sorts ~w(recent accounts domain fetched)

  def filters, do: @filters
  def sorts, do: @sorts
  def page_size, do: @page_size

  @doc "Headline counts for the top of the page."
  @spec summary() :: %{atom() => non_neg_integer()}
  def summary do
    week_ago = DateTime.add(DateTime.utc_now(), -7, :day)

    from(i in Instance,
      select: %{
        total: count(i.id),
        new_this_week: filter(count(i.id), i.inserted_at >= ^week_ago),
        failing: filter(count(i.id), i.delivery_timeout or i.delivery_failures > 0),
        unreachable: filter(count(i.id), not is_nil(i.unreachable_since)),
        banned: filter(count(i.id), i.banned),
        limited: filter(count(i.id), i.unlisted or i.auto_cw)
      }
    )
    |> Repo.one()
  end

  @doc """
  One page of instances with their local footprint.

  Options (string keys, as from params): `"q"` domain substring, `"filter"`
  one of #{inspect(@filters)}, `"sort"` one of #{inspect(@sorts)}, and
  `"offset"`. Returns `%{rows: [map()], total: integer(), more?: boolean()}`;
  each row is `%{instance:, accounts:, followed_by_local:, following_local:,
  statuses:}`.
  """
  @spec list(map()) :: %{rows: [map()], total: non_neg_integer(), more?: boolean()}
  def list(opts \\ %{}) do
    offset = max(parse_int(opts["offset"]), 0)

    filtered =
      from(i in Instance, as: :instance)
      |> filter_query(opts["q"])
      |> filter_flag(opts["filter"])

    total = Repo.aggregate(filtered, :count, :id)

    accounts =
      from(p in Profile,
        where: not is_nil(p.domain),
        group_by: p.domain,
        select: %{domain: p.domain, n: count(p.id)}
      )

    rows =
      from([instance: i] in filtered,
        left_join: a in subquery(accounts),
        on: a.domain == i.domain,
        select: {i, coalesce(a.n, 0)},
        limit: ^@page_size,
        offset: ^offset
      )
      |> sort(opts["sort"])
      |> Repo.all()

    domains = Enum.map(rows, fn {i, _} -> i.domain end)
    followed = followed_by_local(domains)
    following = following_local(domains)
    statuses = statuses_from(domains)

    rows =
      Enum.map(rows, fn {i, n} ->
        key = String.downcase(i.domain)

        %{
          instance: i,
          accounts: n,
          followed_by_local: Map.get(followed, key, 0),
          following_local: Map.get(following, key, 0),
          statuses: Map.get(statuses, key, 0)
        }
      end)

    %{rows: rows, total: total, more?: offset + length(rows) < total}
  end

  defp filter_query(q, term) when is_binary(term) do
    case String.trim(term) do
      "" -> q
      t -> where(q, [instance: i], ilike(i.domain, ^"%#{escape_like(t)}%"))
    end
  end

  defp filter_query(q, _), do: q

  defp filter_flag(q, "failing"),
    do: where(q, [instance: i], i.delivery_timeout or i.delivery_failures > 0)

  defp filter_flag(q, "unreachable"),
    do: where(q, [instance: i], not is_nil(i.unreachable_since))

  defp filter_flag(q, "banned"), do: where(q, [instance: i], i.banned)
  defp filter_flag(q, "limited"), do: where(q, [instance: i], i.unlisted or i.auto_cw)
  defp filter_flag(q, _), do: q

  defp sort(q, "accounts"),
    do: order_by(q, [i, a], desc: coalesce(a.n, 0), asc: i.domain)

  defp sort(q, "domain"), do: order_by(q, [i], asc: i.domain)

  defp sort(q, "fetched"),
    do: order_by(q, [i], desc_nulls_last: i.last_fetched_at, asc: i.domain)

  defp sort(q, _recent), do: order_by(q, [i], desc: i.inserted_at, desc: i.id)

  # Local accounts following someone on each domain.
  defp followed_by_local([]), do: %{}

  defp followed_by_local(domains) do
    from(f in Follower,
      join: remote in Profile,
      on: remote.id == f.profile_id,
      join: local in Profile,
      on: local.id == f.following_id and is_nil(local.domain),
      where: remote.domain in ^domains,
      group_by: remote.domain,
      select: {remote.domain, count(f.id)}
    )
    |> counts()
  end

  # Accounts on each domain following someone local.
  defp following_local([]), do: %{}

  defp following_local(domains) do
    from(f in Follower,
      join: remote in Profile,
      on: remote.id == f.following_id,
      join: local in Profile,
      on: local.id == f.profile_id and is_nil(local.domain),
      where: remote.domain in ^domains,
      group_by: remote.domain,
      select: {remote.domain, count(f.id)}
    )
    |> counts()
  end

  defp statuses_from([]), do: %{}

  defp statuses_from(domains) do
    from(s in Status,
      join: p in Profile,
      on: p.id == s.profile_id,
      where: p.domain in ^domains and is_nil(s.deleted_at),
      group_by: p.domain,
      select: {p.domain, count(s.id)}
    )
    |> counts()
  end

  defp counts(query) do
    query
    |> Repo.all()
    |> Map.new(fn {domain, n} -> {String.downcase(domain), n} end)
  end

  defp parse_int(v) when is_integer(v), do: v

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp parse_int(_), do: 0

  defp escape_like(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
