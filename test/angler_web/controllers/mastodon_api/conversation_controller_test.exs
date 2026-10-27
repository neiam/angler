defmodule AnglerWeb.MastodonAPI.ConversationControllerTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.OAuth
  alias Angler.Statuses

  setup do
    {:ok, %{user: u1, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    {:ok, %{profile: bob}} =
      Accounts.register(%{
        username: "bob",
        email: "bob@example.com",
        password: "passwordOK1"
      })

    %{client: client} = OAuth.first_party_client!()
    {:ok, %{access: read}} = OAuth.issue_token(u1, client, scopes: ["read"])
    {:ok, %{access: write}} = OAuth.issue_token(u1, client, scopes: ["write"])

    {:ok, _} = Statuses.create_local(alice, %{"status" => "hi @bob", "visibility" => "direct"})

    %{alice: alice, bob: bob, read: read, write: write}
  end

  defp auth(conn, t), do: put_req_header(conn, "authorization", "Bearer " <> t)

  test "GET /conversations lists threads with last_status + accounts", ctx do
    conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v1/conversations")
    [conv] = json_response(conn, 200)

    assert is_binary(conv["id"])
    assert conv["last_status"]["content"] =~ "hi"
    [acct] = conv["accounts"]
    assert acct["username"] == "bob"
  end

  test "GET /conversations pages by latest activity with a Link header", ctx do
    {:ok, _carol} = Angler.Profiles.create_profile(%{username: "carol"})

    {:ok, _} =
      Statuses.create_local(ctx.alice, %{"status" => "yo @carol", "visibility" => "direct"})

    # A new message in the older thread moves it back to the top.
    {:ok, _} =
      Statuses.create_local(ctx.alice, %{"status" => "again @bob", "visibility" => "direct"})

    conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v1/conversations", %{"limit" => "1"})
    [newest] = json_response(conn, 200)
    assert newest["last_status"]["content"] =~ "again"

    [link] = get_resp_header(conn, "link")
    [_, next] = Regex.run(~r/<([^>]+)>; rel="next"/, link)
    [older] = auth(ctx.conn, ctx.read) |> get(next) |> json_response(200)
    assert [%{"username" => "carol"}] = older["accounts"]
  end

  test "POST /conversations/:id/read flips unread", ctx do
    [conv] =
      Angler.Conversations.list_mastodon(
        ctx.alice.id,
        Angler.Pagination.MastodonCursor.parse(%{}, 20, 40)
      )

    conn =
      auth(ctx.conn, ctx.write)
      |> post(~p"/api/v1/conversations/#{Integer.to_string(conv.id)}/read")

    body = json_response(conn, 200)
    assert body["unread"] == false
  end

  test "DELETE /conversations/:id hides it for the viewer", ctx do
    [conv] =
      Angler.Conversations.list_mastodon(
        ctx.alice.id,
        Angler.Pagination.MastodonCursor.parse(%{}, 20, 40)
      )

    conn =
      auth(ctx.conn, ctx.write)
      |> delete(~p"/api/v1/conversations/#{Integer.to_string(conv.id)}")

    assert json_response(conn, 200) == %{}
    assert json_response(auth(ctx.conn, ctx.read) |> get(~p"/api/v1/conversations"), 200) == []
  end

  test "GET /timelines/direct returns the last status of each thread", ctx do
    conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v1/timelines/direct")
    [s] = json_response(conn, 200)
    assert s["visibility"] == "direct"
  end
end
