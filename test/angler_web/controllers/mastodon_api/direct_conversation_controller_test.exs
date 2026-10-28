defmodule AnglerWeb.MastodonAPI.DirectConversationControllerTest do
  @moduledoc "The v0.15 DM API: /api/v1.1/direct/conversations and friends."

  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  import Ecto.Query

  alias Angler.Accounts
  alias Angler.OAuth

  setup do
    users =
      for name <- ~w(alice bob carol) do
        {:ok, %{user: u, profile: p}} =
          Accounts.register(%{
            username: name,
            email: "#{name}@example.com",
            password: "passwordOK1"
          })

        %{client: c} = OAuth.first_party_client!()
        {:ok, %{access: token}} = OAuth.issue_token(u, c, scopes: ["read", "write"])
        {String.to_atom(name), %{profile: p, token: token}}
      end

    Map.new(users)
  end

  defp api(conn, who), do: put_req_header(conn, "authorization", "Bearer " <> who.token)
  defp id(who), do: Integer.to_string(who.profile.id)

  defp start!(conn, from, to) do
    conn
    |> api(from)
    |> post(~p"/api/v1.1/direct/conversations", %{"recipient_ids" => Enum.map(to, &id/1)})
    |> json_response(201)
  end

  defp say!(conn, from, cid, text) do
    conn
    |> api(from)
    |> post(~p"/api/v1.1/direct/conversations/#{cid}/messages", %{"message" => text})
    |> json_response(201)
  end

  defp inbox(conn, who, filter \\ "primary") do
    conn
    |> api(who)
    |> get(~p"/api/v1.1/direct/conversations", %{"filter" => filter})
    |> json_response(200)
  end

  test "start, send, and the recipient's request inbox", %{conn: conn} = ctx do
    conv = start!(conn, ctx.alice, [ctx.bob])
    assert conv["type"] == "dm"
    assert [%{"username" => "bob"}] = conv["participants"]

    # No messages yet: nobody's inbox shows it.
    assert inbox(conn, ctx.bob, "requests")["data"] == []

    msg = say!(conn, ctx.alice, conv["id"], "hi bob")
    assert msg["text"] == "hi bob"
    assert msg["is_author"] == true
    assert msg["type"] == "text"

    # Bob doesn't follow Alice and hasn't opened DMs, so it's a request.
    assert inbox(conn, ctx.bob)["data"] == []

    assert [%{"id" => cid, "state" => "request", "unread_count" => 1}] =
             inbox(conn, ctx.bob, "requests")["data"]

    assert cid == conv["id"]

    assert %{"primary" => 0, "requests" => 1} =
             conn |> api(ctx.bob) |> get(~p"/api/v1.1/direct/unread_count") |> json_response(200)

    # One message per unaccepted request.
    assert conn
           |> api(ctx.alice)
           |> post(~p"/api/v1.1/direct/conversations/#{cid}/messages", %{"message" => "again"})
           |> json_response(403)

    # Accepting moves it to primary; replying is fine.
    assert %{"state" => "active"} =
             conn
             |> api(ctx.bob)
             |> post(~p"/api/v1.1/direct/conversations/#{cid}/accept")
             |> json_response(200)

    say!(conn, ctx.bob, cid, "hey alice")
    say!(conn, ctx.alice, cid, "again")

    %{"data" => [newest, _, oldest], "meta" => meta} =
      conn
      |> api(ctx.bob)
      |> get(~p"/api/v1.1/direct/conversations/#{cid}/messages")
      |> json_response(200)

    assert newest["text"] == "again"
    assert oldest["text"] == "hi bob"
    assert meta["has_more"] == false
    assert meta["newest_id"] == newest["id"]
  end

  test "read clears unread; the pointer never moves back", %{conn: conn} = ctx do
    conv = start!(conn, ctx.alice, [ctx.bob])
    m1 = say!(conn, ctx.alice, conv["id"], "one")
    conn |> api(ctx.bob) |> post(~p"/api/v1.1/direct/conversations/#{conv["id"]}/accept")
    m2 = say!(conn, ctx.alice, conv["id"], "two")

    state =
      conn
      |> api(ctx.bob)
      |> post(~p"/api/v1.1/direct/conversations/#{conv["id"]}/read", %{"message_id" => m1["id"]})
      |> json_response(200)

    assert state["unread_count"] == 1
    assert state["last_read_message_id"] == m1["id"]

    state =
      conn
      |> api(ctx.bob)
      |> post(~p"/api/v1.1/direct/conversations/#{conv["id"]}/read")
      |> json_response(200)

    assert state["unread_count"] == 0
    assert state["last_read_message_id"] == m2["id"]
  end

  test "the same people always land in the same conversation", %{conn: conn} = ctx do
    conv = start!(conn, ctx.alice, [ctx.bob])

    again =
      conn
      |> api(ctx.bob)
      |> post(~p"/api/v1.1/direct/conversations", %{"recipient_ids" => [id(ctx.alice)]})
      |> json_response(200)

    assert again["id"] == conv["id"]
  end

  test "group chats: create, send, leave", %{conn: conn} = ctx do
    conv = start!(conn, ctx.alice, [ctx.bob, ctx.carol])
    assert conv["type"] == "group"
    assert conv["participant_count"] == 3

    say!(conn, ctx.alice, conv["id"], "hi both")

    assert [%{"unread_count" => 1}] = inbox(conn, ctx.carol, "requests")["data"]

    assert %{"state" => "left"} =
             conn
             |> api(ctx.carol)
             |> post(~p"/api/v1.1/direct/conversations/#{conv["id"]}/leave")
             |> json_response(200)

    assert conn
           |> api(ctx.carol)
           |> get(~p"/api/v1.1/direct/conversations/#{conv["id"]}")
           |> json_response(404)

    # 1:1s can't be left.
    dm = start!(conn, ctx.alice, [ctx.bob])

    assert conn
           |> api(ctx.alice)
           |> post(~p"/api/v1.1/direct/conversations/#{dm["id"]}/leave")
           |> json_response(422)
  end

  test "deleting a message repoints the conversation", %{conn: conn} = ctx do
    conv = start!(conn, ctx.alice, [ctx.bob])
    m1 = say!(conn, ctx.alice, conv["id"], "keep")
    conn |> api(ctx.bob) |> post(~p"/api/v1.1/direct/conversations/#{conv["id"]}/accept")
    m2 = say!(conn, ctx.alice, conv["id"], "oops")

    assert %{"deleted" => true} =
             conn
             |> api(ctx.alice)
             |> delete(~p"/api/v1.1/direct/conversations/#{conv["id"]}/messages/#{m2["id"]}")
             |> json_response(200)

    shown =
      conn
      |> api(ctx.bob)
      |> get(~p"/api/v1.1/direct/conversations/#{conv["id"]}")
      |> json_response(200)

    assert shown["last_message"]["id"] == m1["id"]
    assert shown["unread_count"] == 1

    # Someone else's message can't be deleted.
    assert conn
           |> api(ctx.bob)
           |> delete(~p"/api/v1.1/direct/conversations/#{conv["id"]}/messages/#{m1["id"]}")
           |> json_response(404)
  end

  test "mute, hide and unhide", %{conn: conn} = ctx do
    conv = start!(conn, ctx.alice, [ctx.bob])
    say!(conn, ctx.alice, conv["id"], "hi")
    cid = conv["id"]

    assert %{"muted" => true} =
             conn
             |> api(ctx.alice)
             |> post(~p"/api/v1.1/direct/conversations/#{cid}/mute")
             |> json_response(200)

    assert %{"hidden" => true} =
             conn
             |> api(ctx.alice)
             |> post(~p"/api/v1.1/direct/conversations/#{cid}/hide")
             |> json_response(200)

    assert inbox(conn, ctx.alice)["data"] == []
    assert [%{"id" => ^cid}] = inbox(conn, ctx.alice, "hidden")["data"]

    conn |> api(ctx.alice) |> post(~p"/api/v1.1/direct/conversations/#{cid}/unhide")
    assert [%{"id" => ^cid, "muted" => true}] = inbox(conn, ctx.alice)["data"]
  end

  test "a conversation others can't see is a 404", %{conn: conn} = ctx do
    conv = start!(conn, ctx.alice, [ctx.bob])

    assert conn
           |> api(ctx.carol)
           |> get(~p"/api/v1.1/direct/conversations/#{conv["id"]}")
           |> json_response(404)
  end

  test "blocked: no new DM to someone who blocks you", %{conn: conn} = ctx do
    {:ok, _} = Angler.Profiles.BlocksMutes.block(ctx.bob.profile, ctx.alice.profile)

    assert conn
           |> api(ctx.alice)
           |> post(~p"/api/v1.1/direct/conversations", %{"recipient_ids" => [id(ctx.bob)]})
           |> json_response(403)
  end

  test "DMs sent by Mastodon clients show up too, and in /api/v1/conversations",
       %{conn: conn} = ctx do
    {:ok, :accepted, _} = Angler.Follows.follow(ctx.bob.profile, ctx.alice.profile)

    conn
    |> api(ctx.alice)
    |> post(~p"/api/v1/statuses", %{"status" => "@bob psst", "visibility" => "direct"})
    |> json_response(200)

    assert [%{"state" => "active", "last_message" => %{"text" => "psst"}}] =
             inbox(conn, ctx.bob)["data"]

    assert [%{"unread" => true, "accounts" => [%{"username" => "alice"}]}] =
             conn |> api(ctx.bob) |> get(~p"/api/v1/conversations") |> json_response(200)
  end

  test "pages with a cursor", %{conn: conn} = ctx do
    for who <- [ctx.bob, ctx.carol] do
      c = start!(conn, ctx.alice, [who])
      say!(conn, ctx.alice, c["id"], "hi")
    end

    %{"data" => [_], "meta" => %{"next_cursor" => cursor}} =
      conn
      |> api(ctx.alice)
      |> get(~p"/api/v1.1/direct/conversations", %{"limit" => "1"})
      |> json_response(200)

    assert is_binary(cursor)

    %{"data" => [_]} =
      conn
      |> api(ctx.alice)
      |> get(~p"/api/v1.1/direct/conversations", %{"limit" => "1", "cursor" => cursor})
      |> json_response(200)
  end

  defp notifications(conn, who, params \\ %{}) do
    conn |> api(who) |> get(~p"/api/v1/notifications", params) |> json_response(200)
  end

  test "notifications: requests stay quiet; accepted ones point at the conversation",
       %{conn: conn} = ctx do
    conv = start!(conn, ctx.alice, [ctx.bob])
    cid = conv["id"]
    say!(conn, ctx.alice, cid, "hi bob")

    # A request doesn't notify, nor show as a mention.
    assert notifications(conn, ctx.bob) == []

    conn |> api(ctx.bob) |> post(~p"/api/v1.1/direct/conversations/#{cid}/accept")
    m2 = say!(conn, ctx.alice, cid, "you there?")

    assert [n] = notifications(conn, ctx.bob, %{"_pe" => "1"})
    assert n["type"] == "direct"
    assert n["direct"] == %{"conversation_id" => cid, "message_id" => m2["id"]}
    assert n["account"]["username"] == "alice"

    # Mastodon clients see a mention, and filter it as one.
    assert [%{"type" => "mention"}] = notifications(conn, ctx.bob)
    assert [_] = notifications(conn, ctx.bob, %{"types" => ["mention"]})
    assert notifications(conn, ctx.bob, %{"exclude_types" => ["mention"]}) == []

    # Deleting the message takes its notification with it.
    conn
    |> api(ctx.alice)
    |> delete(~p"/api/v1.1/direct/conversations/#{cid}/messages/#{m2["id"]}")
    |> json_response(200)

    assert notifications(conn, ctx.bob) == []
  end

  test "notifications: muted and hidden conversations stay quiet", %{conn: conn} = ctx do
    conv = start!(conn, ctx.alice, [ctx.bob])
    cid = conv["id"]
    say!(conn, ctx.alice, cid, "one")
    conn |> api(ctx.bob) |> post(~p"/api/v1.1/direct/conversations/#{cid}/accept")
    conn |> api(ctx.bob) |> post(~p"/api/v1.1/direct/conversations/#{cid}/mute")

    say!(conn, ctx.alice, cid, "two")
    assert notifications(conn, ctx.bob) == []

    conn |> api(ctx.bob) |> post(~p"/api/v1.1/direct/conversations/#{cid}/unmute")
    conn |> api(ctx.bob) |> post(~p"/api/v1.1/direct/conversations/#{cid}/hide")
    say!(conn, ctx.alice, cid, "three")
    assert notifications(conn, ctx.bob) == []

    conn |> api(ctx.bob) |> post(~p"/api/v1.1/direct/conversations/#{cid}/unhide")
    say!(conn, ctx.alice, cid, "four")
    assert [%{"type" => "mention"}] = notifications(conn, ctx.bob)
  end

  test "with new-account DMs off, accounts under 72 hours can't start one", %{conn: conn} = ctx do
    Application.put_env(:angler, :allow_new_account_dms, false)
    on_exit(fn -> Application.delete_env(:angler, :allow_new_account_dms) end)

    assert %{"error" => "You need to wait" <> _} =
             conn
             |> api(ctx.alice)
             |> post(~p"/api/v1.1/direct/conversations", %{"recipient_ids" => [id(ctx.bob)]})
             |> json_response(400)

    assert conn
           |> api(ctx.alice)
           |> post(~p"/api/v1.1/direct/thread/send", %{"to_id" => id(ctx.bob), "message" => "hi"})
           |> json_response(400)

    old = DateTime.add(DateTime.utc_now(), -73 * 3600)

    Angler.Repo.update_all(
      from(u in Angler.Accounts.User, where: u.profile_id == ^ctx.alice.profile.id),
      set: [inserted_at: old]
    )

    start!(conn, ctx.alice, [ctx.bob])
  end
end
