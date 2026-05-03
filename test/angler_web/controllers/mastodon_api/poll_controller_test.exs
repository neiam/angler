defmodule AnglerWeb.MastodonAPI.PollControllerTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.OAuth
  alias Angler.Polls
  alias Angler.Statuses

  setup do
    {:ok, %{user: user, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: client} = OAuth.first_party_client!()
    {:ok, %{access: read}} = OAuth.issue_token(user, client, scopes: ["read"])
    {:ok, %{access: write}} = OAuth.issue_token(user, client, scopes: ["write"])

    {:ok, status} =
      Statuses.create_remote(%{
        profile_id: alice.id,
        visibility: :public,
        caption: "vote",
        rendered: "<p>vote</p>",
        type: "text",
        local: true,
        uri: nil
      })

    {:ok, poll} =
      Polls.create(status, %{
        "options" => ["a", "b", "c"],
        "expires_in" => 3600
      })

    %{alice: alice, status: status, poll: poll, read: read, write: write}
  end

  defp auth(conn, t), do: put_req_header(conn, "authorization", "Bearer " <> t)

  test "GET /polls/:id renders the poll", ctx do
    conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v1/polls/#{Integer.to_string(ctx.poll.id)}")
    body = json_response(conn, 200)
    assert body["id"] == Integer.to_string(ctx.poll.id)
    assert length(body["options"]) == 3
    assert body["voted"] == false
  end

  test "GET /polls/:id 404 unknown", ctx do
    conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v1/polls/999999999")
    assert json_response(conn, 404)
  end

  test "POST /polls/:id/votes records a vote", ctx do
    conn =
      auth(ctx.conn, ctx.write)
      |> post(~p"/api/v1/polls/#{Integer.to_string(ctx.poll.id)}/votes", %{"choices" => ["1"]})

    body = json_response(conn, 200)
    assert body["voted"] == true
    assert body["own_votes"] == [1]
    assert body["voters_count"] == 1
  end

  test "POST /polls/:id/votes rejects too-many on single-choice", ctx do
    conn =
      auth(ctx.conn, ctx.write)
      |> post(~p"/api/v1/polls/#{Integer.to_string(ctx.poll.id)}/votes", %{"choices" => [0, 1]})

    assert json_response(conn, 422)["error"] == "too_many_choices"
  end

  test "Status renderer surfaces the poll on the parent status", ctx do
    conn =
      auth(ctx.conn, ctx.read) |> get(~p"/api/v1/statuses/#{Integer.to_string(ctx.status.id)}")

    body = json_response(conn, 200)
    assert body["poll"]["id"] == Integer.to_string(ctx.poll.id)
  end

  test "POST /statuses with poll attrs creates a poll", ctx do
    conn =
      auth(ctx.conn, ctx.write)
      |> post(~p"/api/v1/statuses", %{
        "status" => "favorite color?",
        "visibility" => "public",
        "poll" => %{"options" => ["red", "blue"], "expires_in" => 3600}
      })

    body = json_response(conn, 200)
    assert body["poll"]["options"]
    assert length(body["poll"]["options"]) == 2
  end
end
