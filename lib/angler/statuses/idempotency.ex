defmodule Angler.Statuses.Idempotency do
  @moduledoc """
  `Idempotency-Key` for `POST /api/v1/statuses` (upstream 5a7f17420): a
  client retrying a post it can't tell went through gets the original
  status back instead of a duplicate.

  Kept in the database rather than a node-local cache because a retry can
  land on another pod. A key is claimed while its request is in flight
  (`status_id` null) — a concurrent repeat gets `:in_flight` (409) — and
  remembers the created status for an hour. Rows are pruned hourly.
  """

  import Ecto.Query, warn: false

  alias Angler.Repo
  alias Angler.Statuses.IdempotencyKey

  @ttl_s 3_600
  # A claim this old is a request that died without releasing it.
  @in_flight_s 60

  @spec claim(integer(), String.t()) :: :claimed | {:existing, integer()} | :in_flight
  def claim(user_id, key) when is_integer(user_id) and is_binary(key) do
    hash = hash(key)
    now = DateTime.utc_now()

    case Repo.get_by(IdempotencyKey, user_id: user_id, key_hash: hash) do
      %IdempotencyKey{status_id: sid} = row when is_integer(sid) ->
        if age_s(row, now) < @ttl_s, do: {:existing, sid}, else: reclaim(row, user_id, hash)

      %IdempotencyKey{} = row ->
        if age_s(row, now) < @in_flight_s, do: :in_flight, else: reclaim(row, user_id, hash)

      nil ->
        insert_claim(user_id, hash)
    end
  end

  @doc "Record the status a claimed key produced."
  @spec complete(integer(), String.t(), integer()) :: :ok
  def complete(user_id, key, status_id) do
    from(k in IdempotencyKey, where: k.user_id == ^user_id and k.key_hash == ^hash(key))
    |> Repo.update_all(set: [status_id: status_id])

    :ok
  end

  @doc "Drop a claim whose request failed, so the client can retry."
  @spec release(integer(), String.t()) :: :ok
  def release(user_id, key) do
    from(k in IdempotencyKey,
      where: k.user_id == ^user_id and k.key_hash == ^hash(key) and is_nil(k.status_id)
    )
    |> Repo.delete_all()

    :ok
  end

  @doc "Delete keys past their hour."
  @spec prune() :: non_neg_integer()
  def prune do
    cutoff = DateTime.add(DateTime.utc_now(), -@ttl_s, :second)
    {n, _} = Repo.delete_all(from k in IdempotencyKey, where: k.inserted_at < ^cutoff)
    n
  end

  defp reclaim(row, user_id, hash) do
    Repo.delete(row)
    insert_claim(user_id, hash)
  end

  defp insert_claim(user_id, hash) do
    case Repo.insert(%IdempotencyKey{user_id: user_id, key_hash: hash},
           on_conflict: :nothing,
           conflict_target: [:user_id, :key_hash]
         ) do
      {:ok, %IdempotencyKey{id: id}} when not is_nil(id) -> :claimed
      # Lost the race to a concurrent request with the same key.
      _ -> :in_flight
    end
  end

  defp age_s(%IdempotencyKey{inserted_at: at}, now), do: DateTime.diff(now, at, :second)
  defp hash(key), do: :crypto.hash(:sha256, key)
end
