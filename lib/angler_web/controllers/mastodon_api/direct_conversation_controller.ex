defmodule AnglerWeb.MastodonAPI.DirectConversationController do
  @moduledoc """
  Pixelfed v0.15's direct-message API (`/api/v1.1/direct/...`), which the
  new app uses for DMs and group chats (upstream 9c81a75ad):

    * GET    unread_count
    * GET    conversations?filter=primary|requests|hidden&limit&cursor
    * POST   conversations                      — find or start, `recipient_ids[]`
    * GET    conversations/:id
    * GET    conversations/:id/messages?limit&max_id&min_id
    * POST   conversations/:id/messages         — `message`, `media_ids[]`, `in_reply_to_id`
    * DELETE conversations/:id/messages/:message_id
    * POST   conversations/:id/{read,accept,mute,unmute,hide,unhide,leave}

  Messages are `:direct` statuses (see `Angler.Conversations`), so they
  federate as ordinary Mastodon-style DMs and show up for Mastodon clients.
  Lists use upstream's `{data, meta}` envelope.
  """

  use AnglerWeb, :controller

  @wait_message "You need to wait a bit before you can DM another account"

  import Ecto.Query, only: [from: 2]

  alias Angler.Conversations
  alias Angler.Conversations.{Conversation, Participant}
  alias Angler.Profiles.{BlocksMutes, Profile}
  alias Angler.Repo
  alias Angler.Statuses
  alias Angler.Statuses.Status
  alias Angler.Stories
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.MastodonAPI.Media, as: MediaJSON
  alias AnglerWeb.Plugs.BearerAuth

  @max_message_length 2000
  @max_media 4

  ## Inbox

  def unread_count(conn, _params) do
    %{profile: me} = BearerAuth.current_scope(conn)
    %{primary: p, requests: r} = Conversations.unread_count(me.id)
    json(conn, %{"primary" => p, "requests" => r})
  end

  def index(conn, params) do
    %{profile: me} = BearerAuth.current_scope(conn)

    filter =
      if params["filter"] in ~w(primary requests hidden), do: params["filter"], else: "primary"

    limit = params["limit"] |> to_int(20) |> min(40) |> max(1)

    rows = Conversations.list(me.id, filter, limit, decode_cursor(params["cursor"]))

    next =
      case List.last(rows) do
        %Participant{} = last when length(rows) == limit -> encode_cursor(last)
        _ -> nil
      end

    json(conn, %{
      "data" => Enum.map(rows, &render_conversation(&1, me.id)),
      "meta" => %{"filter" => filter, "next_cursor" => next, "prev_cursor" => nil}
    })
  end

  def show(conn, %{"id" => id}) do
    %{profile: me} = BearerAuth.current_scope(conn)

    with_row(conn, me, id, fn row -> json(conn, render_conversation(row, me.id)) end)
  end

  # Find or start the conversation with exactly these people (plus me).
  def create(conn, params) do
    %{profile: me, user: user} = BearerAuth.current_scope(conn)

    with {:ok, ids} <- recipient_ids(params["recipient_ids"], me.id),
         {:ok, recipients} <- recipients(ids),
         members = [me.id | ids],
         existing = Repo.get_by(Conversation, participants_hash: Conversation.hash(members)),
         :ok <- check_groups(members),
         :ok <- if(existing, do: :ok, else: check_new(user, me, recipients)) do
      conversation = existing || Conversations.find_or_create!(members, me.id)
      Conversations.reopen(conversation.id, me.id)
      row = Conversations.get(me.id, conversation.id)

      conn
      |> put_status(if(existing, do: :ok, else: :created))
      |> json(render_conversation(row, me.id))
    else
      {:error, status, message} -> conn |> put_status(status) |> json(%{"error" => message})
    end
  end

  ## Messages

  def messages(conn, %{"id" => id} = params) do
    %{profile: me} = BearerAuth.current_scope(conn)
    limit = params["limit"] |> to_int(20) |> min(50) |> max(1)

    with_row(conn, me, id, fn row ->
      {rows, more?} =
        Conversations.messages(row.conversation_id, me.id, limit,
          max_id: positive(params["max_id"]),
          min_id: positive(params["min_id"])
        )

      json(conn, %{
        "data" => Enum.map(rows, &render_message(&1, row.conversation_id, me.id)),
        "meta" => %{
          "has_more" => more?,
          "newest_id" => rows |> List.first() |> id_or_nil(),
          "oldest_id" => rows |> List.last() |> id_or_nil()
        }
      })
    end)
  end

  def send_message(conn, %{"id" => id} = params) do
    %{profile: me} = BearerAuth.current_scope(conn)

    with_row(conn, me, id, fn row ->
      others = Enum.reject(row.conversation.participants, &(&1.profile_id == me.id))

      with {:ok, text} <- message_text(params["message"]),
           {:ok, media_ids} <- media_ids(params["media_ids"]),
           :ok <-
             if(text == "" and media_ids == [],
               do: {:error, 422, "A message needs text or media."},
               else: :ok
             ),
           :ok <- check_can_send(row, me, others),
           {:ok, reply_to} <- reply_to(row.conversation_id, params["in_reply_to_id"]),
           {:ok, status} <-
             Statuses.create_local(me, %{
               "status" => mention_prefix(others) <> text,
               "visibility" => "direct",
               "media_ids" => Enum.map(media_ids, &Integer.to_string/1),
               "in_reply_to_id" => reply_to && Integer.to_string(reply_to),
               "sensitive" => params["sensitive"] in [true, "true", "1"]
             }) do
        Angler.Statuses.Workers.StatusDeliver.enqueue_for(status)

        conn
        |> put_status(:created)
        |> json(render_message(status, row.conversation_id, me.id))
      else
        {:error, status, message} -> conn |> put_status(status) |> json(%{"error" => message})
        {:error, reason} -> conn |> put_status(422) |> json(%{"error" => to_string(reason)})
      end
    end)
  end

  def delete_message(conn, %{"id" => id, "message_id" => mid}) do
    %{profile: me} = BearerAuth.current_scope(conn)

    with_row(conn, me, id, fn row ->
      with {:ok, status_id} <- parse_id(mid),
           true <- Conversations.message?(row.conversation_id, status_id),
           {:ok, _} <- Statuses.delete_local(status_id, me) do
        json(conn, %{"deleted" => true})
      else
        _ -> not_found(conn)
      end
    end)
  end

  ## Per-participant state

  def read(conn, %{"id" => id} = params) do
    state_action(conn, id, &Conversations.mark_read(&1, positive(params["message_id"])))
  end

  def accept(conn, %{"id" => id}), do: state_action(conn, id, &Conversations.accept/1)
  def mute(conn, %{"id" => id}), do: state_action(conn, id, &Conversations.mute/1)
  def unmute(conn, %{"id" => id}), do: state_action(conn, id, &Conversations.unmute/1)
  def hide(conn, %{"id" => id}), do: state_action(conn, id, &Conversations.hide/1)
  def unhide(conn, %{"id" => id}), do: state_action(conn, id, &Conversations.unhide/1)

  def leave(conn, %{"id" => id}) do
    %{profile: me} = BearerAuth.current_scope(conn)

    with_row(conn, me, id, fn row ->
      case Conversations.leave(row) do
        {:ok, left} ->
          json(conn, render_state(left))

        {:error, :not_a_group} ->
          conn |> put_status(422) |> json(%{"error" => "Only group conversations can be left."})
      end
    end)
  end

  defp state_action(conn, id, fun) do
    %{profile: me} = BearerAuth.current_scope(conn)
    with_row(conn, me, id, fn row -> json(conn, render_state(fun.(row))) end)
  end

  ## Checks

  defp with_row(conn, %Profile{id: me}, id, fun) do
    with {:ok, cid} <- parse_id(id),
         %Participant{} = row <- Conversations.get(me, cid) do
      fun.(row)
    else
      _ -> not_found(conn)
    end
  end

  defp recipient_ids(ids, me) when is_list(ids) do
    parsed = Enum.map(ids, &parse_id/1)

    cond do
      Enum.any?(parsed, &(&1 == :error)) ->
        {:error, 422, "recipient_ids must be ids."}

      true ->
        ids = parsed |> Enum.map(fn {:ok, n} -> n end) |> Enum.uniq() |> Enum.reject(&(&1 == me))

        cond do
          ids == [] ->
            {:error, 422, "A conversation needs at least two participants."}

          length(ids) > Conversations.max_participants() - 1 ->
            {:error, 422, "Too many participants."}

          true ->
            {:ok, ids}
        end
    end
  end

  defp recipient_ids(_, _), do: {:error, 422, "recipient_ids is required."}

  defp recipients(ids) do
    found = Repo.all(from p in Profile, where: p.id in ^ids and is_nil(p.status))

    if length(found) == length(ids),
      do: {:ok, found},
      else: {:error, 404, "One or more recipients could not be found."}
  end

  defp check_groups(members) do
    if length(Enum.uniq(members)) > 2 and not groups_enabled?(),
      do: {:error, 422, "Group conversations are not enabled."},
      else: :ok
  end

  # Starting a new conversation: you can't DM someone who blocks you, or put
  # someone you block in a group.
  defp check_new(user, me, recipients) do
    if Conversations.can_initiate?(user),
      do: check_new(me, recipients),
      else: {:error, 400, @wait_message}
  end

  defp check_new(me, [single]) do
    if BlocksMutes.blocked?(single.id, me.id),
      do: {:error, 403, "You cannot message this account."},
      else: :ok
  end

  defp check_new(me, recipients) do
    if Enum.any?(recipients, &BlocksMutes.blocked?(me.id, &1.id)),
      do: {:error, 422, "You have blocked one of these accounts."},
      else: :ok
  end

  # 1:1 only: the other person mustn't block you, and while they haven't
  # accepted your request you get one message (upstream sender_limit).
  defp check_can_send(%Participant{conversation: %Conversation{type: "dm"}} = row, me, [other]) do
    cond do
      BlocksMutes.blocked?(other.profile_id, me.id) ->
        {:error, 403, "You cannot message this account."}

      other.state == "request" and is_nil(other.profile.domain) and
          sent_count(row.conversation_id, me.id) >= 1 ->
        {:error, 403, "You can send more messages once your request is accepted."}

      true ->
        :ok
    end
  end

  defp check_can_send(_row, _me, others) do
    if Enum.all?(others, &(&1.profile.status != nil)),
      do: {:error, 403, "Nobody in this conversation can be reached."},
      else: :ok
  end

  defp sent_count(conversation_id, profile_id) do
    Repo.aggregate(
      from(m in Angler.Conversations.Message,
        join: s in Status,
        on: s.id == m.status_id and is_nil(s.deleted_at),
        where: m.conversation_id == ^conversation_id and s.profile_id == ^profile_id
      ),
      :count
    )
  end

  defp message_text(nil), do: {:ok, ""}

  defp message_text(m) when is_binary(m) do
    m = String.trim(m)

    if String.length(m) > @max_message_length,
      do: {:error, 422, "The message may not be longer than #{@max_message_length} characters."},
      else: {:ok, m}
  end

  defp message_text(_), do: {:error, 422, "message must be a string."}

  defp media_ids(nil), do: {:ok, []}

  defp media_ids(ids) when is_list(ids) do
    parsed = ids |> Enum.map(&parse_id/1) |> Enum.uniq()

    cond do
      Enum.any?(parsed, &(&1 == :error)) -> {:error, 422, "Invalid media_ids."}
      length(parsed) > @max_media -> {:error, 422, "Too many attachments."}
      true -> {:ok, Enum.map(parsed, fn {:ok, n} -> n end)}
    end
  end

  defp media_ids(_), do: {:error, 422, "Invalid media_ids."}

  defp reply_to(_cid, nil), do: {:ok, nil}

  defp reply_to(cid, id) do
    with {:ok, n} <- parse_id(id),
         true <- Conversations.message?(cid, n) do
      {:ok, n}
    else
      _ -> {:error, 422, "Invalid in_reply_to_id."}
    end
  end

  # Messages address everyone else by mention — that is what makes them a
  # DM between exactly these people, here and on Mastodon.
  defp mention_prefix(others) do
    Enum.map_join(others, "", fn %Participant{profile: p} ->
      "@" <> if(p.domain, do: "#{p.username}@#{p.domain}", else: p.username) <> " "
    end)
  end

  defp groups_enabled?, do: Application.get_env(:angler, :dm_groups_enabled, true) == true

  ## Rendering

  defp render_conversation(%Participant{conversation: c} = row, viewer_id) do
    others = Enum.reject(c.participants, &(&1.profile_id == viewer_id))

    %{
      "id" => Integer.to_string(c.id),
      "type" => c.type,
      "name" => c.name,
      "participants" => Enum.map(others, &Account.render(&1.profile, pe: true)),
      "participant_count" => length(c.participants),
      "state" => row.state,
      "unread_count" => row.unread_count,
      "muted" => not is_nil(row.muted_at),
      "hidden" => not is_nil(row.hidden_at),
      "last_read_message_id" =>
        row.last_read_message_id && Integer.to_string(row.last_read_message_id),
      "last_message" =>
        case c.last_message do
          %Status{deleted_at: nil, profile_id: author} = s ->
            if BlocksMutes.blocked?(viewer_id, author),
              do: nil,
              else: render_message(s, c.id, viewer_id)

          _ ->
            nil
        end,
      "created_at" => ts(c.inserted_at),
      "updated_at" => ts(row.last_activity_at || c.last_message_at || c.updated_at)
    }
  end

  defp render_state(%Participant{} = row) do
    %{
      "id" => Integer.to_string(row.conversation_id),
      "state" => row.state,
      "unread_count" => row.unread_count,
      "muted" => not is_nil(row.muted_at),
      "hidden" => not is_nil(row.hidden_at),
      "last_read_message_id" =>
        row.last_read_message_id && Integer.to_string(row.last_read_message_id)
    }
  end

  defp render_message(%Status{} = s, conversation_id, viewer_id) do
    s = Repo.preload(s, [:media_attachments])
    media = s.media_attachments
    text = body_text(s)
    {type, meta} = Stories.message_meta(s) || {message_type(media, text), nil}

    %{
      "id" => Integer.to_string(s.id),
      "conversation_id" => Integer.to_string(conversation_id),
      "sender_id" => Integer.to_string(s.profile_id),
      "is_author" => s.profile_id == viewer_id,
      "type" => type,
      "text" => if(text == "", do: nil, else: text),
      "media" => Enum.map(media, &MediaJSON.render/1),
      "meta" => meta,
      "sensitive" => s.is_nsfw,
      "in_reply_to_id" => s.in_reply_to_id && Integer.to_string(s.in_reply_to_id),
      "edited_at" => ts(s.edited_at),
      "created_at" => ts(s.inserted_at)
    }
  end

  # The caption without the leading @mentions that address the message.
  defp body_text(%Status{caption: caption}) do
    (caption || "")
    |> String.replace(~r/\A(\s*@[\w.\-]+(@[\w.\-]+)?)+\s*/u, "")
    |> String.trim()
  end

  defp message_type([], text) do
    if Regex.match?(~r{\Ahttps?://\S+\z}, text), do: "link", else: "text"
  end

  defp message_type(media, _text) do
    kinds = Enum.map(media, &MediaJSON.render(&1)["type"]) |> Enum.uniq()

    case {kinds, length(media)} do
      {["video"], 1} -> "video"
      {["video"], _} -> "videos"
      {["image"], 1} -> "photo"
      {["image"], _} -> "photos"
      _ -> "media"
    end
  end

  defp ts(nil), do: nil
  defp ts(%DateTime{} = dt), do: dt |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp id_or_nil(nil), do: nil
  defp id_or_nil(%Status{id: id}), do: Integer.to_string(id)

  ## Cursors and params

  defp encode_cursor(%Participant{last_activity_at: at, id: id}) do
    Base.url_encode64("#{DateTime.to_unix(at, :microsecond)}:#{id}", padding: false)
  end

  defp decode_cursor(c) when is_binary(c) do
    with {:ok, raw} <- Base.url_decode64(c, padding: false),
         [us, id] <- String.split(raw, ":"),
         {us, ""} <- Integer.parse(us),
         {id, ""} <- Integer.parse(id),
         {:ok, at} <- DateTime.from_unix(us, :microsecond) do
      {at, id}
    else
      _ -> nil
    end
  end

  defp decode_cursor(_), do: nil

  defp positive(v) do
    case parse_id(v) do
      {:ok, n} when n > 0 -> n
      _ -> nil
    end
  end

  defp to_int(v, default) do
    case parse_id(v) do
      {:ok, n} -> n
      _ -> default
    end
  end

  defp parse_id(n) when is_integer(n), do: {:ok, n}

  defp parse_id(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
end
