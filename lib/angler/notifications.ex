defmodule Angler.Notifications do
  @moduledoc """
  Per-recipient notifications produced by interactions on local profiles
  (favourite, reblog, follow, mention).

  Notifications are local-only — they are derived from federation activities
  but never federated themselves. `notify/1` is idempotent via the unique
  index on `(recipient_id, type, account_id, status_id)`; callers can safely
  invoke it multiple times for the same event.
  """

  import Ecto.Query, warn: false

  alias Angler.Notifications.Notification
  alias Angler.Profiles.Profile
  alias Angler.Repo

  @type type :: String.t()

  @default_limit 20
  @max_limit 30

  ## Producer

  @doc """
  Insert a notification, skipping if (recipient, type, account, status)
  already exists or if the recipient and account are the same profile
  (no self-notifications). Returns `{:ok, notification}` for new rows,
  `:noop` for skipped/duplicates.
  """
  @spec notify(map()) :: {:ok, Notification.t()} | :noop | {:error, term()}
  def notify(%{recipient_id: rid, account_id: aid}) when rid == aid, do: :noop

  def notify(attrs) when is_map(attrs) do
    # Bail early if the recipient is not a local profile.
    case Repo.get(Profile, attrs.recipient_id) do
      %Profile{domain: nil} ->
        attrs
        |> Map.put_new(:dismissed, false)
        |> Notification.changeset()
        |> Repo.insert(
          on_conflict: :nothing,
          conflict_target: [:recipient_id, :type, :account_id, :status_id]
        )
        |> case do
          {:ok, %Notification{id: nil}} ->
            :noop

          {:ok, n} ->
            Angler.Push.Workers.PushDeliver.fan_out(n.id)
            Angler.Streaming.broadcast_notification(n)
            {:ok, n}

          err ->
            err
        end

      _ ->
        :noop
    end
  end

  ## Reads

  @doc """
  List notifications for `recipient_id`. Supports the same Mastodon cursor
  shape as timelines: `:max_id`, `:min_id`, `:since_id`, `:limit`. Filters:

    * `:types` — list of allowed types (e.g. `["mention", "favourite"]`)
    * `:exclude_types` — list of types to exclude
    * `:account_id` — only notifications from this account
  """
  @spec list(integer(), map()) :: {[Notification.t()], [Notification.t()]}
  def list(recipient_id, params) when is_integer(recipient_id) and is_map(params) do
    limit = parse_limit(params["limit"])

    base =
      from n in Notification,
        where: n.recipient_id == ^recipient_id and n.dismissed == false,
        preload: [:account, status: :profile]

    base
    |> apply_filters(params)
    |> apply_cursor(params, limit)
    |> Repo.all()
    |> finalize(params, limit)
  end

  @doc "Get a single notification owned by `recipient_id`."
  @spec get(integer(), integer()) :: Notification.t() | nil
  def get(recipient_id, id) when is_integer(recipient_id) and is_integer(id) do
    Notification
    |> where([n], n.id == ^id and n.recipient_id == ^recipient_id)
    |> preload([:account, status: :profile])
    |> Repo.one()
  end

  @doc "Mark a single notification dismissed. Idempotent."
  @spec dismiss(integer(), integer()) :: :ok
  def dismiss(recipient_id, id) when is_integer(recipient_id) and is_integer(id) do
    {_, _} =
      from(n in Notification,
        where: n.id == ^id and n.recipient_id == ^recipient_id and n.dismissed == false
      )
      |> Repo.update_all(set: [dismissed: true, updated_at: DateTime.utc_now()])

    :ok
  end

  @doc "Mark every undismissed notification for `recipient_id` dismissed."
  @spec clear(integer()) :: :ok
  def clear(recipient_id) when is_integer(recipient_id) do
    {_, _} =
      from(n in Notification,
        where: n.recipient_id == ^recipient_id and n.dismissed == false
      )
      |> Repo.update_all(set: [dismissed: true, updated_at: DateTime.utc_now()])

    :ok
  end

  ## Internals

  defp parse_limit(nil), do: @default_limit

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n |> max(1) |> min(@max_limit)
      _ -> @default_limit
    end
  end

  defp parse_limit(n) when is_integer(n), do: n |> max(1) |> min(@max_limit)
  defp parse_limit(_), do: @default_limit

  defp apply_filters(q, params) do
    q
    |> filter_types(params["types"])
    |> filter_exclude_types(params["exclude_types"])
    |> filter_account(params["account_id"])
  end

  defp filter_types(q, nil), do: q
  defp filter_types(q, []), do: q

  defp filter_types(q, types) when is_list(types) do
    where(q, [n], n.type in ^types)
  end

  defp filter_exclude_types(q, nil), do: q
  defp filter_exclude_types(q, []), do: q

  defp filter_exclude_types(q, types) when is_list(types) do
    where(q, [n], n.type not in ^types)
  end

  defp filter_account(q, nil), do: q

  defp filter_account(q, account_id) when is_binary(account_id) do
    case Integer.parse(account_id) do
      {id, ""} -> where(q, [n], n.account_id == ^id)
      _ -> q
    end
  end

  defp filter_account(q, account_id) when is_integer(account_id) do
    where(q, [n], n.account_id == ^account_id)
  end

  defp apply_cursor(q, params, limit) do
    cursor = %{
      max_id: parse_id(params["max_id"]),
      min_id: parse_id(params["min_id"]),
      since_id: parse_id(params["since_id"])
    }

    cond do
      cursor.min_id ->
        from n in q,
          where: n.id > ^cursor.min_id,
          order_by: [asc: n.id],
          limit: ^limit

      true ->
        q
        |> maybe_max(cursor.max_id)
        |> maybe_since(cursor.since_id)
        |> order_by([n], desc: n.id)
        |> limit(^limit)
    end
  end

  defp maybe_max(q, nil), do: q
  defp maybe_max(q, id), do: where(q, [n], n.id < ^id)
  defp maybe_since(q, nil), do: q
  defp maybe_since(q, id), do: where(q, [n], n.id > ^id)

  defp parse_id(nil), do: nil
  defp parse_id(""), do: nil

  defp parse_id(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_id(n) when is_integer(n), do: n

  defp finalize(rows, params, _limit) do
    rows =
      if params["min_id"] && rows != [] do
        Enum.reverse(rows)
      else
        rows
      end

    {rows, rows}
  end
end
