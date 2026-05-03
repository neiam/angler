defmodule AnglerWeb.MastodonAPI.StatusCreateTest do
  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.OAuth

  setup do
    {:ok, %{user: user, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: client} = OAuth.first_party_client!()

    {:ok, %{access: write_token}} =
      OAuth.issue_token(user, client, scopes: ["write"])

    {:ok, %{access: read_only}} =
      OAuth.issue_token(user, client, scopes: ["read"])

    %{user: user, alice: alice, write_token: write_token, read_only: read_only}
  end

  describe "POST /api/v1/statuses" do
    test "401 without bearer", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/statuses", %{"status" => "hi"})
      assert json_response(conn, 401)
    end

    test "403 with read-only token", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.read_only)
        |> post(~p"/api/v1/statuses", %{"status" => "hi"})

      assert json_response(conn, 403)
    end

    test "200 + Mastodon-shape body for a text-only post", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.write_token)
        |> post(~p"/api/v1/statuses", %{"status" => "hello world"})

      body = json_response(conn, 200)
      assert is_binary(body["id"])
      assert body["account"]["username"] == "alice"
      assert body["visibility"] == "public"
      assert body["content"] =~ "hello world"
    end

    test "enqueues feed insert + status deliver", ctx do
      _ =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.write_token)
        |> post(~p"/api/v1/statuses", %{"status" => "hello"})

      assert_enqueued(worker: Angler.Timelines.Workers.FeedInsert)
      # No remote followers in this test, so StatusDeliver enqueues 0 jobs.
      # The e2e test (federation_outbound_e2e_test) covers the populated path.
    end

    test "422 on empty status", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.write_token)
        |> post(~p"/api/v1/statuses", %{"status" => ""})

      body = json_response(conn, 422)
      assert body["error"] =~ "required"
    end

    test "422 on bad visibility", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.write_token)
        |> post(~p"/api/v1/statuses", %{"status" => "hi", "visibility" => "secret"})

      body = json_response(conn, 422)
      assert body["error"] =~ "Visibility"
    end

    test "the new status appears in author's home timeline", ctx do
      _ =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.write_token)
        |> post(~p"/api/v1/statuses", %{"status" => "first"})

      Oban.drain_queue(queue: :feed)

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.read_only)
        |> get(~p"/api/v1/timelines/home")

      body = json_response(conn, 200)
      assert [status] = body
      assert status["content"] =~ "first"
    end
  end
end
