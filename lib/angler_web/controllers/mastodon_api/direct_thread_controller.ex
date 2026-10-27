defmodule AnglerWeb.MastodonAPI.DirectThreadController do
  @moduledoc """
  Pixelfed-shape direct-message endpoints. Each "message" is a `:direct`
  status; threads are paired participants. We map onto our existing
  `Statuses` + `Conversations`/`Mention` pipeline rather than a separate
  schema.

    * GET    /api/v1.1/direct/thread?pid=               — thread with peer
    * POST   /api/v1.1/direct/thread/send               — send a message
    * DELETE /api/v1.1/direct/thread/message            — delete one (own)
    * POST   /api/v1.1/direct/thread/read               — mark thread read
    * POST   /api/v1.1/direct/thread/mute               — mute peer (uses
      `BlocksMutes.mute/3` with notifications hidden)
    * POST   /api/v1.1/direct/thread/unmute
    * POST   /api/v1.1/direct/thread/media              — upload media for DM
  """

  use AnglerWeb, :controller

  alias Angler.Conversations
  alias Angler.Media
  alias Angler.Profiles
  alias Angler.Profiles.{BlocksMutes, Profile}
  alias Angler.Statuses
  alias Angler.Statuses.Status
  alias AnglerWeb.MastodonAPI.Media, as: MediaJSON
  alias AnglerWeb.Plugs.BearerAuth

  ## GET /direct/thread

  def thread(conn, params) do
    %{profile: viewer} = BearerAuth.current_scope(conn)

    with {:ok, pid} <- parse_id(params["pid"]),
         %Profile{} = peer <- Profiles.get_profile(pid) do
      max_id = parse_id(params["max_id"]) |> ok_or_nil()
      min_id = parse_id(params["min_id"]) |> ok_or_nil()
      conversation = Conversations.between(viewer.id, peer.id)

      messages =
        case conversation do
          nil ->
            []

          c ->
            {rows, _} = Conversations.messages(c.id, viewer.id, 8, max_id: max_id, min_id: min_id)
            rows
        end

      json(conn, %{
        "id" => Integer.to_string(peer.id),
        # The DM v2 conversation this thread is (upstream adds it).
        "conversation_id" => conversation && Integer.to_string(conversation.id),
        "name" => peer.name || peer.username,
        "username" => peer.username,
        "avatar" => peer.avatar_path || "",
        "url" => Profiles.url(peer),
        "muted" => BlocksMutes.mute_ids_for(viewer.id) |> Enum.member?(peer.id),
        "isLocal" => is_nil(peer.domain),
        "domain" => peer.domain,
        "messages" => Enum.map(messages, &render_message(&1, viewer.id))
      })
    else
      _ -> not_found(conn)
    end
  end

  ## POST /direct/thread/send

  def send(conn, params) do
    %{profile: actor} = BearerAuth.current_scope(conn)

    with {:ok, to_id} <- parse_id(params["to_id"]),
         %Profile{} = peer when peer.id != actor.id <- Profiles.get_profile(to_id),
         {:ok, message} <- params["message"] |> validate_message(),
         :ok <- check_block(actor, peer) do
      media_ids = params["media_ids"] || []

      attrs = %{
        "status" => "@#{peer.username} #{message}",
        "visibility" => "direct",
        "media_ids" => media_ids
      }

      case Statuses.create_local(actor, attrs) do
        {:ok, status} ->
          # A DM to a remote account has to be delivered; this never was.
          Angler.Statuses.Workers.StatusDeliver.enqueue_for(status)
          json(conn, render_message(status, actor.id))

        {:error, reason} ->
          validation_error(conn, %{"_" => [to_string(reason)]})
      end
    else
      {:error, :blocked} -> conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})
      {:error, :too_long} -> validation_error(conn, %{"message" => ["max 500 chars"]})
      {:error, :empty} -> validation_error(conn, %{"message" => ["is required"]})
      _ -> not_found(conn)
    end
  end

  defp validate_message(nil), do: {:error, :empty}
  defp validate_message(""), do: {:error, :empty}
  defp validate_message(s) when is_binary(s) and byte_size(s) > 500, do: {:error, :too_long}
  defp validate_message(s) when is_binary(s), do: {:ok, s}
  defp validate_message(_), do: {:error, :empty}

  defp check_block(%Profile{id: actor_id}, %Profile{id: peer_id}) do
    if BlocksMutes.blocked?(peer_id, actor_id), do: {:error, :blocked}, else: :ok
  end

  ## DELETE /direct/thread/message

  def delete_message(conn, params) do
    %{profile: actor} = BearerAuth.current_scope(conn)

    with {:ok, sid} <- parse_id(params["id"]),
         {:ok, _} <- Statuses.delete_local(sid, actor) do
      json(conn, [200])
    else
      {:error, :forbidden} -> conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})
      _ -> not_found(conn)
    end
  end

  ## POST /direct/thread/read

  def read(conn, params) do
    %{profile: viewer} = BearerAuth.current_scope(conn)

    with {:ok, pid} <- parse_id(params["pid"]) do
      with %{id: cid} <- Conversations.between(viewer.id, pid),
           %{} = row <- Conversations.get(viewer.id, cid) do
        Conversations.mark_read(row)
      end

      json(conn, [200])
    else
      _ -> not_found(conn)
    end
  end

  ## POST /direct/thread/mute & /unmute

  def mute(conn, params) do
    %{profile: actor} = BearerAuth.current_scope(conn)

    with {:ok, pid} <- parse_id(params["id"]),
         %Profile{} = peer <- Profiles.get_profile(pid),
         {:ok, _} <- BlocksMutes.mute(actor, peer, notifications: true) do
      json(conn, [200])
    else
      {:error, :self_mute} -> validation_error(conn, %{"id" => ["cannot mute yourself"]})
      _ -> not_found(conn)
    end
  end

  def unmute(conn, params) do
    %{profile: actor} = BearerAuth.current_scope(conn)

    with {:ok, pid} <- parse_id(params["id"]),
         %Profile{} = peer <- Profiles.get_profile(pid) do
      BlocksMutes.unmute(actor, peer)
      json(conn, [200])
    else
      _ -> not_found(conn)
    end
  end

  ## POST /direct/thread/media

  def upload_media(conn, params) do
    %{profile: actor} = BearerAuth.current_scope(conn)

    case Map.get(params, "file") do
      nil ->
        validation_error(conn, %{"file" => ["is required"]})

      upload ->
        case Media.upload(actor, upload, params) do
          {:ok, asset} -> json(conn, MediaJSON.render(asset))
          {:error, reason} -> validation_error(conn, %{"_" => [to_string(reason)]})
        end
    end
  end

  ## Internals

  defp render_message(%Status{} = s, viewer_id) do
    media =
      case s.media_attachments do
        list when is_list(list) and list != [] ->
          first = hd(list)
          Angler.Media.Storage.url(first, :original)

        _ ->
          nil
      end

    %{
      "id" => Integer.to_string(s.id),
      "hidden" => false,
      "isAuthor" => s.profile_id == viewer_id,
      "type" => if(media, do: "media", else: "text"),
      "text" => strip_handle(s.caption || ""),
      "media" => media,
      "carousel" =>
        case s.media_attachments do
          list when is_list(list) -> Enum.map(list, &MediaJSON.render/1)
          _ -> []
        end,
      "created_at" => DateTime.to_iso8601(s.inserted_at),
      "seen" => true,
      "reportId" => Integer.to_string(s.id)
    }
  end

  # The send endpoint prepends `@username ` to satisfy the mention-extraction
  # pipeline; strip the leading handle from the rendered text so the client
  # doesn't echo it back.
  defp strip_handle(text) do
    case Regex.run(~r/^@\S+\s+(.*)$/s, text) do
      [_, rest] -> rest
      _ -> text
    end
  end

  defp parse_id(nil), do: :error

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}
  defp parse_id(_), do: :error

  defp ok_or_nil({:ok, v}), do: v
  defp ok_or_nil(_), do: nil

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})

  defp validation_error(conn, errors),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{"error" => "Validation failed", "errors" => errors})
end
