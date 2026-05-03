defmodule Angler.Statuses.Scheduling do
  @moduledoc """
  Lifecycle for scheduled local statuses.

    * `schedule/2` stores the request params for later firing.
    * `list/2` / `get/2` / `update_scheduled_at/3` / `delete/2` — owner-scoped.
    * `fire_due/0` — picked up by `Workers.ScheduledFire` on a cron tick;
      claims and fires each due row in a single UPDATE…RETURNING + post-claim
      `Statuses.create_local/2`.
  """

  import Ecto.Query, warn: false

  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses
  alias Angler.Statuses.Scheduled

  @min_lead_seconds 5 * 60

  ## Lead-time guard

  @doc "Smallest delay (seconds) we accept on a `scheduled_at` value."
  def min_lead_seconds, do: @min_lead_seconds

  @doc """
  Whether `attrs["scheduled_at"]` (ISO-8601 string or DateTime) is more than
  five minutes in the future. Mastodon's threshold; below it the request is
  treated as an immediate post.
  """
  @spec scheduled?(map()) :: boolean()
  def scheduled?(attrs) when is_map(attrs) do
    case parse_at(attrs["scheduled_at"]) do
      {:ok, at} -> DateTime.diff(at, DateTime.utc_now(), :second) > @min_lead_seconds
      _ -> false
    end
  end

  ## Schedule

  @spec schedule(Profile.t(), map()) :: {:ok, Scheduled.t()} | {:error, atom()}
  def schedule(%Profile{domain: nil} = profile, attrs) when is_map(attrs) do
    case parse_at(attrs["scheduled_at"]) do
      {:ok, at} ->
        %{
          profile_id: profile.id,
          params: drop_unserializable(attrs),
          media_ids: parse_media_ids(attrs["media_ids"]),
          scheduled_at: at
        }
        |> Scheduled.changeset()
        |> Repo.insert()

      _ ->
        {:error, :bad_scheduled_at}
    end
  end

  def schedule(_, _), do: {:error, :not_local_profile}

  ## Owner-scoped reads

  @spec list(integer(), keyword()) :: [Scheduled.t()]
  def list(profile_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Repo.all(
      from s in Scheduled,
        where: s.profile_id == ^profile_id and is_nil(s.fired_at),
        order_by: [desc: s.id],
        limit: ^limit
    )
  end

  @spec get(integer(), integer()) :: Scheduled.t() | nil
  def get(profile_id, id) when is_integer(profile_id) and is_integer(id) do
    Repo.get_by(Scheduled, id: id, profile_id: profile_id)
  end

  @spec update_scheduled_at(Scheduled.t(), DateTime.t() | String.t()) ::
          {:ok, Scheduled.t()} | {:error, atom() | Ecto.Changeset.t()}
  def update_scheduled_at(%Scheduled{} = row, %DateTime{} = at) do
    if DateTime.diff(at, DateTime.utc_now(), :second) > @min_lead_seconds do
      row |> Ecto.Changeset.change(scheduled_at: at) |> Repo.update()
    else
      {:error, :too_soon}
    end
  end

  def update_scheduled_at(row, raw) when is_binary(raw) do
    case parse_at(raw) do
      {:ok, at} -> update_scheduled_at(row, at)
      _ -> {:error, :bad_scheduled_at}
    end
  end

  @spec delete(integer(), integer()) :: :ok
  def delete(profile_id, id) do
    {_, _} =
      from(s in Scheduled, where: s.profile_id == ^profile_id and s.id == ^id)
      |> Repo.delete_all()

    :ok
  end

  ## Firing (called by the Oban cron worker)

  @doc """
  Fire every due, unfired row. Returns `{n_fired, n_failed}`.

  Each row is claimed via `UPDATE … SET fired_at = now() WHERE fired_at IS NULL`
  in a transaction so a concurrent run of the worker can't double-fire it.
  """
  @spec fire_due() :: {non_neg_integer(), non_neg_integer()}
  def fire_due do
    now = DateTime.utc_now()

    Repo.all(
      from s in Scheduled,
        where: is_nil(s.fired_at) and s.scheduled_at <= ^now,
        order_by: [asc: s.scheduled_at],
        limit: 200,
        select: s
    )
    |> Enum.reduce({0, 0}, fn row, {ok, fail} ->
      case fire_one(row) do
        :ok -> {ok + 1, fail}
        :error -> {ok, fail + 1}
      end
    end)
  end

  defp fire_one(%Scheduled{} = row) do
    Repo.transaction(fn ->
      claim =
        from(s in Scheduled, where: s.id == ^row.id and is_nil(s.fired_at))
        |> Repo.update_all(set: [fired_at: DateTime.utc_now()])

      case claim do
        {1, _} ->
          profile = Repo.get!(Profile, row.profile_id)
          attrs = (row.params || %{}) |> Map.put("media_ids", row.media_ids)

          case Statuses.create_local(profile, attrs) do
            {:ok, _status} -> :ok
            _ -> Repo.rollback(:create_failed)
          end

        _ ->
          # Another worker beat us to it.
          :ok
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      _ -> :error
    end
  end

  ## Internals

  defp parse_at(nil), do: :error
  defp parse_at(""), do: :error

  defp parse_at(%DateTime{} = dt), do: {:ok, dt}

  defp parse_at(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_at(_), do: :error

  # Keep the JSON-serializable subset of the request body. Drop file uploads
  # (media_ids are referenced separately) and binary data.
  defp drop_unserializable(attrs) do
    attrs
    |> Map.drop(["media_ids", "scheduled_at"])
    |> Enum.reject(fn
      {_k, v} when is_struct(v) -> true
      {_k, v} when is_function(v) -> true
      _ -> false
    end)
    |> Map.new()
  end

  defp parse_media_ids(nil), do: []
  defp parse_media_ids([]), do: []

  defp parse_media_ids(list) when is_list(list) do
    Enum.flat_map(list, fn
      n when is_integer(n) ->
        [n]

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} -> [n]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp parse_media_ids(_), do: []
end
