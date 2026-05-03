defmodule AnglerWeb.MastodonAPI.StatusInteractionsTest do
  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.OAuth
  alias Angler.Profiles
  alias Angler.Statuses

  setup do
    {:ok, %{user: user, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: client} = OAuth.first_party_client!()
    {:ok, %{access: write}} = OAuth.issue_token(user, client, scopes: ["write"])
    {:ok, %{access: read}} = OAuth.issue_token(user, client, scopes: ["read"])

    {:ok, bob} = Profiles.create_profile(%{username: "bob"})

    {:ok, status} =
      Statuses.create_remote(%{
        profile_id: bob.id,
        visibility: :public,
        caption: "hi",
        rendered: "<p>hi</p>",
        type: "text",
        local: true,
        uri: nil
      })

    %{alice: alice, bob: bob, status: status, write: write, read: read}
  end

  defp post_with(conn, token, path) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> post(path)
  end

  ## Favourite

  describe "POST /statuses/:id/favourite" do
    test "401 without bearer", ctx do
      conn = post(ctx.conn, ~p"/api/v1/statuses/#{Integer.to_string(ctx.status.id)}/favourite")
      assert json_response(conn, 401)
    end

    test "200 + Status with favourited=true and incremented count", ctx do
      conn =
        post_with(
          ctx.conn,
          ctx.write,
          ~p"/api/v1/statuses/#{Integer.to_string(ctx.status.id)}/favourite"
        )

      body = json_response(conn, 200)
      assert body["favourited"] == true
      assert body["favourites_count"] == 1
    end

    test "404 for unknown status", ctx do
      conn = post_with(ctx.conn, ctx.write, ~p"/api/v1/statuses/999999999/favourite")
      assert json_response(conn, 404)
    end

    test "404 when target is not visible to viewer", ctx do
      {:ok, private_status} =
        Statuses.create_remote(%{
          profile_id: ctx.bob.id,
          visibility: :private,
          caption: "secret",
          rendered: "<p>secret</p>",
          type: "text",
          local: true
        })

      conn =
        post_with(
          ctx.conn,
          ctx.write,
          ~p"/api/v1/statuses/#{Integer.to_string(private_status.id)}/favourite"
        )

      assert json_response(conn, 404)
    end
  end

  describe "POST /statuses/:id/unfavourite" do
    test "200 + favourited=false", ctx do
      Statuses.favourite(ctx.alice, ctx.status)

      conn =
        post_with(
          ctx.conn,
          ctx.write,
          ~p"/api/v1/statuses/#{Integer.to_string(ctx.status.id)}/unfavourite"
        )

      body = json_response(conn, 200)
      assert body["favourited"] == false
      assert body["favourites_count"] == 0
    end

    test "idempotent (200 even if not favourited)", ctx do
      conn =
        post_with(
          ctx.conn,
          ctx.write,
          ~p"/api/v1/statuses/#{Integer.to_string(ctx.status.id)}/unfavourite"
        )

      assert json_response(conn, 200)
    end
  end

  ## Reblog

  describe "POST /statuses/:id/reblog" do
    test "200 + reblogged=true", ctx do
      conn =
        post_with(
          ctx.conn,
          ctx.write,
          ~p"/api/v1/statuses/#{Integer.to_string(ctx.status.id)}/reblog"
        )

      body = json_response(conn, 200)
      assert body["reblogged"] == true
      assert body["reblogs_count"] == 1
    end

    test "422 on private status", ctx do
      {:ok, private_status} =
        Statuses.create_remote(%{
          profile_id: ctx.alice.id,
          visibility: :private,
          caption: "secret",
          rendered: "<p>secret</p>",
          type: "text",
          local: true
        })

      conn =
        post_with(
          ctx.conn,
          ctx.write,
          ~p"/api/v1/statuses/#{Integer.to_string(private_status.id)}/reblog"
        )

      assert json_response(conn, 422)["error"] =~ "cannot be reblogged"
    end
  end

  describe "POST /statuses/:id/unreblog" do
    test "200 + reblogged=false", ctx do
      Statuses.reblog(ctx.alice, ctx.status)

      conn =
        post_with(
          ctx.conn,
          ctx.write,
          ~p"/api/v1/statuses/#{Integer.to_string(ctx.status.id)}/unreblog"
        )

      body = json_response(conn, 200)
      assert body["reblogged"] == false
      assert body["reblogs_count"] == 0
    end
  end

  ## Bookmark

  describe "POST /statuses/:id/bookmark" do
    test "200 + bookmarked=true", ctx do
      conn =
        post_with(
          ctx.conn,
          ctx.write,
          ~p"/api/v1/statuses/#{Integer.to_string(ctx.status.id)}/bookmark"
        )

      body = json_response(conn, 200)
      assert body["bookmarked"] == true
    end

    test "is idempotent", ctx do
      _ =
        post_with(
          ctx.conn,
          ctx.write,
          ~p"/api/v1/statuses/#{Integer.to_string(ctx.status.id)}/bookmark"
        )

      conn =
        post_with(
          ctx.conn,
          ctx.write,
          ~p"/api/v1/statuses/#{Integer.to_string(ctx.status.id)}/bookmark"
        )

      assert json_response(conn, 200)["bookmarked"] == true
    end
  end

  describe "POST /statuses/:id/unbookmark" do
    test "200 + bookmarked=false", ctx do
      _ =
        post_with(
          ctx.conn,
          ctx.write,
          ~p"/api/v1/statuses/#{Integer.to_string(ctx.status.id)}/bookmark"
        )

      conn =
        post_with(
          ctx.conn,
          ctx.write,
          ~p"/api/v1/statuses/#{Integer.to_string(ctx.status.id)}/unbookmark"
        )

      body = json_response(conn, 200)
      assert body["bookmarked"] == false
    end
  end

  ## Viewer overlay end-to-end through GET

  describe "viewer overlay reaches GET /statuses/:id" do
    test "favourited reflected when read with same bearer", ctx do
      Statuses.favourite(ctx.alice, ctx.status)

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.read)
        |> get(~p"/api/v1/statuses/#{Integer.to_string(ctx.status.id)}")

      body = json_response(conn, 200)
      assert body["favourited"] == true
    end
  end
end
