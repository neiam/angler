defmodule AnglerWeb.MastodonAPI.TrendsControllerTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.OAuth
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

    {:ok, _} =
      Statuses.create_local(alice, %{
        "status" => "post #photography is great",
        "visibility" => "public"
      })

    {:ok, _} =
      Statuses.create_local(alice, %{
        "status" => "another #photography post",
        "visibility" => "public"
      })

    {:ok, hot_status} =
      Statuses.create_local(alice, %{"status" => "the hot one", "visibility" => "public"})

    Statuses.inc_counter(hot_status.id, :likes_count, 5)

    %{read: read, alice: alice, hot_status: hot_status}
  end

  defp auth(conn, t), do: put_req_header(conn, "authorization", "Bearer " <> t)

  test "GET /trends/tags returns top hashtags with history", ctx do
    conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v1/trends/tags")
    body = json_response(conn, 200)
    assert is_list(body)
    [first | _] = body
    assert first["name"] == "photography"
    assert hd(first["history"])["uses"] == "2"
  end

  test "GET /trends/statuses ranks by engagement", ctx do
    conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v1/trends/statuses")
    [first | _] = json_response(conn, 200)
    assert first["id"] == Integer.to_string(ctx.hot_status.id)
  end

  test "GET /trends/links returns []", ctx do
    conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v1/trends/links")
    assert [] = json_response(conn, 200)
  end
end
