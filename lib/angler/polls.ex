defmodule Angler.Polls do
  @moduledoc """
  Poll lifecycle. A poll is owned by a single status; voting is profile-scoped
  with a unique `(poll, profile, option)` row to enforce single-choice and
  prevent option-level double-votes.
  """

  import Ecto.Query, warn: false

  alias Angler.Polls.{Option, Poll, Vote}
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses.Status

  @max_options 8
  @min_options 2
  @max_option_chars 50
  @max_expires_in 7 * 24 * 60 * 60

  @doc "Maximum number of options allowed per poll."
  def max_options, do: @max_options

  ## Reads

  @spec get(integer()) :: Poll.t() | nil
  def get(id) when is_integer(id) do
    Repo.get(Poll, id) |> Repo.preload(:options)
  end

  @spec get_for_status(integer()) :: Poll.t() | nil
  def get_for_status(status_id) when is_integer(status_id) do
    Repo.get_by(Poll, status_id: status_id) |> Repo.preload(:options)
  end

  @spec voted_option_ids(integer(), integer()) :: [integer()]
  def voted_option_ids(poll_id, profile_id) do
    Repo.all(
      from v in Vote,
        where: v.poll_id == ^poll_id and v.profile_id == ^profile_id,
        select: v.option_id
    )
  end

  @doc """
  Whether the poll has expired.
  """
  @spec expired?(Poll.t()) :: boolean()
  def expired?(%Poll{expires_at: at}), do: DateTime.compare(DateTime.utc_now(), at) == :gt

  ## Create

  @doc """
  Create a poll attached to `status`. `attrs` is a map shaped like Mastodon's
  `poll[]` form fields: `%{"options" => [...], "expires_in" => secs, "multiple"
  => bool, "hide_totals" => bool}`.
  """
  @spec create(Status.t(), map()) :: {:ok, Poll.t()} | {:error, atom() | Ecto.Changeset.t()}
  def create(%Status{} = status, attrs) when is_map(attrs) do
    options = parse_options(attrs["options"])
    expires_in = parse_expires_in(attrs["expires_in"])

    cond do
      options == [] ->
        {:error, :options_required}

      length(options) < @min_options ->
        {:error, :too_few_options}

      length(options) > @max_options ->
        {:error, :too_many_options}

      Enum.any?(options, &(byte_size(&1) > @max_option_chars)) ->
        {:error, :option_too_long}

      is_nil(expires_in) ->
        {:error, :bad_expires_in}

      expires_in < 60 ->
        {:error, :expires_too_soon}

      expires_in > @max_expires_in ->
        {:error, :expires_too_late}

      true ->
        do_create(status, options, expires_in, attrs)
    end
  end

  defp do_create(%Status{id: status_id}, options, expires_in, attrs) do
    Repo.transaction(fn ->
      {:ok, poll} =
        %{
          status_id: status_id,
          expires_at: DateTime.add(DateTime.utc_now(), expires_in, :second),
          multiple: truthy?(attrs["multiple"]),
          hide_totals: truthy?(attrs["hide_totals"])
        }
        |> Poll.changeset()
        |> Repo.insert()

      Enum.with_index(options)
      |> Enum.each(fn {title, idx} ->
        {:ok, _} =
          %{poll_id: poll.id, position: idx, title: title}
          |> Option.changeset()
          |> Repo.insert()
      end)

      Repo.preload(poll, :options, force: true)
    end)
  end

  ## Vote

  @doc """
  Cast `option_indices` (0-based, ordered the same as the poll's options) for
  `voter`. Idempotent per (poll, voter, option). Single-choice polls accept
  exactly one index; multi-choice accept 1+.
  """
  @spec vote(Poll.t(), Profile.t(), [non_neg_integer()]) ::
          {:ok, Poll.t()} | {:error, atom()}
  def vote(%Poll{} = poll, %Profile{} = voter, option_indices) when is_list(option_indices) do
    cond do
      expired?(poll) ->
        {:error, :poll_expired}

      option_indices == [] ->
        {:error, :no_choices}

      not poll.multiple and length(option_indices) > 1 ->
        {:error, :too_many_choices}

      true ->
        do_vote(poll, voter, option_indices)
    end
  end

  defp do_vote(%Poll{} = poll, %Profile{} = voter, indices) do
    options = Repo.all(from o in Option, where: o.poll_id == ^poll.id, order_by: o.position)
    by_position = Map.new(options, fn o -> {o.position, o} end)

    if Enum.any?(indices, &(not Map.has_key?(by_position, &1))) do
      {:error, :unknown_option}
    else
      Repo.transaction(fn ->
        already = voted_option_ids(poll.id, voter.id) |> MapSet.new()
        first_vote? = MapSet.size(already) == 0

        {inserted_count, _} =
          indices
          |> Enum.map(&Map.fetch!(by_position, &1))
          |> Enum.map(fn opt ->
            %{
              id: Angler.Snowflake.next(),
              poll_id: poll.id,
              option_id: opt.id,
              profile_id: voter.id,
              inserted_at: DateTime.utc_now()
            }
          end)
          |> then(fn rows ->
            Repo.insert_all(Vote, rows,
              on_conflict: :nothing,
              conflict_target: [:poll_id, :profile_id, :option_id],
              returning: [:option_id]
            )
          end)

        if inserted_count > 0 do
          inserted_option_ids =
            indices
            |> Enum.map(&Map.fetch!(by_position, &1).id)
            |> Enum.reject(fn oid -> MapSet.member?(already, oid) end)

          if inserted_option_ids != [] do
            from(o in Option, where: o.id in ^inserted_option_ids)
            |> Repo.update_all(inc: [votes_count: 1])
          end

          if first_vote? do
            from(p in Poll, where: p.id == ^poll.id) |> Repo.update_all(inc: [voters_count: 1])
          end
        end

        get(poll.id)
      end)
      |> case do
        {:ok, poll} -> {:ok, poll}
        err -> err
      end
    end
  end

  ## Internals

  defp parse_options(list) when is_list(list) do
    Enum.flat_map(list, fn
      v when is_binary(v) ->
        case String.trim(v) do
          "" -> []
          s -> [s]
        end

      _ ->
        []
    end)
  end

  defp parse_options(_), do: []

  defp parse_expires_in(nil), do: nil
  defp parse_expires_in(""), do: nil
  defp parse_expires_in(n) when is_integer(n), do: n

  defp parse_expires_in(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_expires_in(_), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false
end
