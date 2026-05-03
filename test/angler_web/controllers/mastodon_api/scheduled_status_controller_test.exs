defmodule AnglerWeb.MastodonAPI.ScheduledStatusControllerTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.OAuth
  alias Angler.Statuses.Scheduling

  defp future_iso(seconds_from_now) do
    DateTime.utc_now() |> DateTime.add(seconds_from_now, :second) |> DateTime.to_iso8601()
  end

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

    %{alice: alice, read: read, write: write}
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  test "POST /statuses with scheduled_at returns ScheduledStatus shape", ctx do
    conn =
      ctx.conn
      |> auth(ctx.write)
      |> post(~p"/api/v1/statuses", %{
        "status" => "later",
        "visibility" => "public",
        "scheduled_at" => future_iso(900)
      })

    body = json_response(conn, 200)
    assert is_binary(body["id"])
    assert is_binary(body["scheduled_at"])
    assert body["params"]["status"] == "later"
  end

  test "POST /statuses with scheduled_at within 5 min posts immediately", ctx do
    conn =
      ctx.conn
      |> auth(ctx.write)
      |> post(~p"/api/v1/statuses", %{
        "status" => "right now",
        "visibility" => "public",
        "scheduled_at" => future_iso(60)
      })

    body = json_response(conn, 200)
    # Real Status JSON has 'content' and no 'params'.
    assert is_binary(body["content"])
    refute Map.has_key?(body, "params")
  end

  test "GET /scheduled_statuses lists own", ctx do
    {:ok, _} =
      Scheduling.schedule(ctx.alice, %{
        "status" => "x",
        "visibility" => "public",
        "scheduled_at" => future_iso(900)
      })

    conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v1/scheduled_statuses")
    [hit] = json_response(conn, 200)
    assert hit["params"]["status"] == "x"
  end

  test "GET /scheduled_statuses/:id 404 when not owner", ctx do
    {:ok, %{user: bob_user, profile: bob}} =
      Accounts.register(%{
        username: "bob",
        email: "bob@example.com",
        password: "passwordOK1"
      })

    {:ok, row} =
      Scheduling.schedule(bob, %{
        "status" => "x",
        "visibility" => "public",
        "scheduled_at" => future_iso(900)
      })

    conn =
      auth(ctx.conn, ctx.read)
      |> get(~p"/api/v1/scheduled_statuses/#{Integer.to_string(row.id)}")

    assert json_response(conn, 404)
    _ = bob_user
  end

  test "PUT updates scheduled_at; rejects too-soon", ctx do
    {:ok, row} =
      Scheduling.schedule(ctx.alice, %{
        "status" => "x",
        "visibility" => "public",
        "scheduled_at" => future_iso(900)
      })

    conn =
      auth(ctx.conn, ctx.write)
      |> put(~p"/api/v1/scheduled_statuses/#{Integer.to_string(row.id)}", %{
        "scheduled_at" => future_iso(1800)
      })

    assert json_response(conn, 200)["scheduled_at"]

    conn =
      auth(ctx.conn, ctx.write)
      |> put(~p"/api/v1/scheduled_statuses/#{Integer.to_string(row.id)}", %{
        "scheduled_at" => future_iso(60)
      })

    assert json_response(conn, 422)["error"] =~ "too soon"
  end

  test "DELETE removes the row", ctx do
    {:ok, row} =
      Scheduling.schedule(ctx.alice, %{
        "status" => "x",
        "visibility" => "public",
        "scheduled_at" => future_iso(900)
      })

    conn =
      auth(ctx.conn, ctx.write)
      |> delete(~p"/api/v1/scheduled_statuses/#{Integer.to_string(row.id)}")

    assert json_response(conn, 200) == %{}
    refute Scheduling.get(ctx.alice.id, row.id)
  end
end
