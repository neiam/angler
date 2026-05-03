defmodule AnglerWeb.MastodonAPI.NotificationControllerTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.Notifications
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
    {:ok, %{access: read}} = OAuth.issue_token(user, client, scopes: ["read"])
    {:ok, %{access: write}} = OAuth.issue_token(user, client, scopes: ["write"])

    {:ok, bob} = Profiles.create_profile(%{username: "bob"})

    {:ok, status} =
      Statuses.create_remote(%{
        profile_id: alice.id,
        visibility: :public,
        caption: "x",
        rendered: "<p>x</p>",
        type: "text",
        local: true,
        uri: nil
      })

    # Bob favourites alice's status — generates one notification for alice.
    Statuses.favourite(bob, status)

    %{alice: alice, bob: bob, status: status, read: read, write: write}
  end

  defp get_with(conn, token, path) do
    conn |> put_req_header("authorization", "Bearer " <> token) |> get(path)
  end

  defp post_with(conn, token, path) do
    conn |> put_req_header("authorization", "Bearer " <> token) |> post(path)
  end

  describe "GET /notifications" do
    test "401 without bearer", ctx do
      conn = get(ctx.conn, ~p"/api/v1/notifications")
      assert json_response(conn, 401)
    end

    test "200 with the favourite notification + status payload", ctx do
      conn = get_with(ctx.conn, ctx.read, ~p"/api/v1/notifications")

      assert [n] = json_response(conn, 200)
      assert n["type"] == "favourite"
      assert n["account"]["username"] == "bob"
      assert n["status"]["id"] == Integer.to_string(ctx.status.id)
    end

    test "filter via types[]=favourite returns the row, mention filter excludes it", ctx do
      conn = get_with(ctx.conn, ctx.read, ~p"/api/v1/notifications?types[]=mention")
      assert [] = json_response(conn, 200)

      conn = get_with(ctx.conn, ctx.read, ~p"/api/v1/notifications?types[]=favourite")
      assert [_] = json_response(conn, 200)
    end
  end

  describe "GET /notifications/:id" do
    test "200 for owned notification", ctx do
      [%{id: nid}] = Angler.Repo.all(Angler.Notifications.Notification)
      conn = get_with(ctx.conn, ctx.read, ~p"/api/v1/notifications/#{Integer.to_string(nid)}")

      body = json_response(conn, 200)
      assert body["id"] == Integer.to_string(nid)
    end

    test "404 for someone else's notification", ctx do
      # Create a notification for bob (not alice) and try to fetch it as alice.
      {:ok, _other} = Profiles.create_profile(%{username: "carol"})

      {:ok, nbob} =
        Notifications.notify(%{
          recipient_id: ctx.bob.id,
          account_id: ctx.alice.id,
          type: "follow"
        })

      conn = get_with(ctx.conn, ctx.read, ~p"/api/v1/notifications/#{Integer.to_string(nbob.id)}")
      assert json_response(conn, 404)
    end
  end

  describe "POST /notifications/:id/dismiss" do
    test "dismisses one and removes it from the index", ctx do
      [%{id: nid}] = Angler.Repo.all(Angler.Notifications.Notification)

      conn =
        post_with(
          ctx.conn,
          ctx.write,
          ~p"/api/v1/notifications/#{Integer.to_string(nid)}/dismiss"
        )

      assert json_response(conn, 200) == %{}

      conn = get_with(ctx.conn, ctx.read, ~p"/api/v1/notifications")
      assert [] = json_response(conn, 200)
    end
  end

  describe "POST /notifications/clear" do
    test "dismisses everything", ctx do
      conn = post_with(ctx.conn, ctx.write, ~p"/api/v1/notifications/clear")
      assert json_response(conn, 200) == %{}

      conn = get_with(ctx.conn, ctx.read, ~p"/api/v1/notifications")
      assert [] = json_response(conn, 200)
    end
  end
end
