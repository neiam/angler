defmodule Angler.Federation.Workers.InboxValidator do
  @moduledoc """
  Per-user inbox worker: verify the HTTP signature on a stored payload, dedup
  via `federation_activities`, and dispatch to the activity handlers.

  See plans/federation/queues/inbox_validator.md.
  """

  use Oban.Worker,
    queue: :federation_inbound,
    max_attempts: 4

  # First contact with an actor we can't fetch right now (timeout, 5xx) is
  # retried rather than dropped: the sender already got its 202 and won't
  # send again (upstream RetriesWhenActorUnavailable). Same cadence.
  @actor_retry_delays [180, 900, 3600]

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: Enum.at(@actor_retry_delays, attempt - 1, List.last(@actor_retry_delays))

  alias Angler.Federation.Activity
  alias Angler.Federation.Actor
  alias Angler.Federation.Bans
  alias Angler.Federation.FollowersSync
  alias Angler.Federation.HTTPSignature
  alias Angler.Federation.Workers.ActivityHandler
  alias Angler.Repo

  @doc "Enqueue an inbound activity for verification + handling."
  @spec enqueue(integer() | nil, map(), binary(), map(), String.t()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(recipient_id, headers, raw_body, payload, request_path) do
    # `activity_id` + `actor_url` are duplicated at the top level so Oban's
    # `unique:` can dedupe re-deliveries within a 5-minute window. The
    # database-level unique on federation_activities is the durable guard.
    %{
      "recipient_id" => recipient_id,
      "headers" => headers,
      "raw_body" => Base.encode64(raw_body),
      "payload" => payload,
      "path" => request_path,
      "activity_id" => payload["id"],
      "actor_url" => payload["actor"]
    }
    |> __MODULE__.new(unique: unique_opts())
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        attempt: attempt,
        max_attempts: max_attempts,
        args:
          %{
            "headers" => headers,
            "raw_body" => raw_b64,
            "payload" => payload,
            "path" => path
          } = args
      }) do
    retry? = attempt < max_attempts
    raw_body = Base.decode64!(raw_b64)
    actor_url = Map.get(payload, "actor")

    host = (is_binary(actor_url) && URI.parse(actor_url).host) || ""

    cond do
      not is_binary(actor_url) ->
        log_rejected(payload, actor_url, :missing_actor)

      Bans.banned?(host) ->
        log_rejected(payload, actor_url, :banned)

      Angler.Admin.instance_suspended?(host) ->
        log_rejected(payload, actor_url, :defederated)

      true ->
        verify_and_dispatch(
          headers,
          raw_body,
          payload,
          actor_url,
          path,
          args["recipient_id"],
          retry?
        )
    end
  end

  defp verify_and_dispatch(headers, raw_body, payload, actor_url, path, recipient_id, retry?) do
    headers_list = Enum.into(headers, [])
    # Only a key owned by the claimed actor verifies — a valid signature from
    # anyone else's key is not this actor speaking.
    key_resolver = &Actor.public_key_for(&1, actor_url)

    case HTTPSignature.verify(:post, path, headers_list, raw_body, key_resolver) do
      :ok ->
        FollowersSync.handle_inbound(headers, actor_url)
        record_and_dispatch(payload, raw_body, actor_url, recipient_id)

      {:error, reason} ->
        # Try once more after refreshing the actor (rotation defence).
        case Actor.refresh(actor_url) do
          {:ok, _} ->
            case HTTPSignature.verify(
                   :post,
                   path,
                   headers_list,
                   raw_body,
                   key_resolver
                 ) do
              :ok ->
                FollowersSync.handle_inbound(headers, actor_url)
                record_and_dispatch(payload, raw_body, actor_url, recipient_id)

              {:error, _} ->
                log_rejected(payload, actor_url, reason)
            end

          {:error, fetch_error} ->
            if retry? and Angler.Federation.HTTP.transient_error?(fetch_error),
              do: {:error, {:actor_unavailable, fetch_error}},
              else: log_rejected(payload, actor_url, reason)
        end
    end
  end

  defp record_and_dispatch(payload, raw_body, actor_url, recipient_id) do
    activity_attrs = %{
      direction: :inbound,
      activity_id: payload["id"],
      activity_type: payload["type"],
      actor_url: actor_url,
      object_type: object_type(payload),
      object_id: object_id(payload),
      payload: payload,
      raw_body: raw_body,
      status: :delivered,
      delivered_at: DateTime.utc_now()
    }

    case Activity.changeset(activity_attrs) |> Repo.insert(on_conflict: :nothing) do
      {:ok, %Activity{id: nil}} ->
        # Duplicate — already processed.
        :ok

      {:ok, _} ->
        ActivityHandler.enqueue(payload, actor_url, recipient_id)
        :ok

      {:error, _changeset} ->
        # Unique conflict via different path; treat as duplicate.
        :ok
    end
  end

  defp log_rejected(payload, actor_url, reason) do
    %{
      direction: :inbound,
      activity_id: payload["id"],
      activity_type: payload["type"],
      actor_url: actor_url,
      payload: payload,
      status: :rejected,
      error: format_reason(reason)
    }
    |> Activity.changeset()
    |> Repo.insert(on_conflict: :nothing)

    :ok
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp object_type(%{"object" => %{"type" => t}}) when is_binary(t), do: t
  defp object_type(_), do: nil

  defp object_id(%{"object" => %{"id" => id}}) when is_binary(id), do: id
  defp object_id(%{"object" => id}) when is_binary(id), do: id
  defp object_id(_), do: nil

  defp unique_opts do
    [
      period: 300,
      fields: [:args],
      keys: [:activity_id, :actor_url]
    ]
  end
end
