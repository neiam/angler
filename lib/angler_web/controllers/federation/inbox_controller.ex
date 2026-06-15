defmodule AnglerWeb.Federation.InboxController do
  @moduledoc """
  POST /f/inbox (shared) and POST /users/:username/inbox (per-user).

  The plug performs cheap rejections only:
    * Body must be a JSON object with `id` and `type` strings.
    * `URI.parse(body["id"]).host` must not be banned.
    * Per-user variant: username must resolve to a local profile.

  HTTP signature verification happens in the Oban worker, not here, so a
  flood doesn't tie up web workers. We always reply 202 once enqueued, 400
  on rejection — no error detail leaks (matches Mastodon/Pixelfed).

  See plans/federation/endpoints/post_shared_inbox.md.
  """

  use AnglerWeb, :controller

  alias Angler.Federation.Bans
  alias Angler.Federation.Workers.{InboxValidator, InboxWorker}
  alias Angler.Profiles
  alias AnglerWeb.Plugs.RawBodyReader

  def shared(conn, _params) do
    path = conn.request_path

    handle(conn, fn payload, headers, raw_body ->
      InboxWorker.enqueue(headers, raw_body, payload, path)
    end)
  end

  def instance(conn, _params) do
    # The instance-actor inbox (`/i/actor/inbox`) receives relay `Accept`s and
    # firehose `Announce`s. Valid activities are enqueued like the shared
    # inbox; anything else (crawler probes, junk) is swallowed with a 202 so we
    # don't leak which payloads we route.
    raw = RawBodyReader.raw_body(conn)
    headers = headers_to_map(conn)

    with {:ok, payload} when is_map(payload) <- decode_body(raw, conn.body_params),
         :ok <- check_required(payload),
         :ok <- check_banned(payload) do
      {:ok, _job} = InboxWorker.enqueue(headers, raw, payload, conn.request_path)
      send_resp(conn, 202, "")
    else
      _ -> send_resp(conn, 202, "")
    end
  end

  def user(conn, %{"username" => username}) do
    case Profiles.get_local_by_username(username) do
      nil ->
        send_resp(conn, 404, "")

      profile ->
        path = conn.request_path

        handle(conn, fn payload, headers, raw_body ->
          InboxValidator.enqueue(profile.id, headers, raw_body, payload, path)
        end)
    end
  end

  ## Internals

  defp handle(conn, enqueue_fn) do
    raw = RawBodyReader.raw_body(conn)
    headers = headers_to_map(conn)

    with {:ok, payload} when is_map(payload) <- decode_body(raw, conn.body_params),
         :ok <- check_required(payload),
         :ok <- check_banned(payload) do
      {:ok, _job} = enqueue_fn.(payload, headers, raw)
      send_resp(conn, 202, "")
    else
      _ -> send_resp(conn, 400, "")
    end
  end

  # Plug.Parsers may have already parsed the body into conn.body_params, in
  # which case `raw` is the same bytes; either way we have the parsed map.
  defp decode_body(_raw, body_params) when is_map(body_params) and map_size(body_params) > 0,
    do: {:ok, body_params}

  defp decode_body(raw, _) when is_binary(raw) and byte_size(raw) > 0 do
    case Jason.decode(raw) do
      {:ok, m} when is_map(m) -> {:ok, m}
      _ -> {:error, :bad_body}
    end
  end

  defp decode_body(_, _), do: {:error, :empty_body}

  defp check_required(%{"id" => id, "type" => type}) when is_binary(id) and is_binary(type),
    do: :ok

  defp check_required(_), do: {:error, :missing_fields}

  defp check_banned(%{"id" => id}) do
    case URI.parse(id) do
      %URI{host: host} when is_binary(host) ->
        if Bans.banned?(host), do: {:error, :banned}, else: :ok

      _ ->
        {:error, :bad_id}
    end
  end

  defp headers_to_map(conn) do
    # Plug normalizes :host out of req_headers (it carries it on conn.host),
    # but HTTP signatures verify against `host:` as a header, so we re-inject.
    base = Map.new(conn.req_headers, fn {k, v} -> {String.downcase(k), v} end)
    Map.put_new(base, "host", conn.host)
  end
end
