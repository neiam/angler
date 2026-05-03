defmodule AnglerWeb.MastodonAPI.StatusLifecycleTest do
  @moduledoc "DELETE /statuses/:id, GET /:id/context, pin/unpin + /accounts/:id/pinned."

  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.OAuth
  alias Angler.Profiles
  alias Angler.Statuses

  setup do
    {:ok, %{user: u, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: client} = OAuth.first_party_client!()
    {:ok, %{access: read}} = OAuth.issue_token(u, client, scopes: ["read"])
    {:ok, %{access: write}} = OAuth.issue_token(u, client, scopes: ["write"])

    %{alice: alice, read: read, write: write}
  end

  defp auth(conn, t), do: put_req_header(conn, "authorization", "Bearer " <> t)

  ## DELETE

  describe "DELETE /api/v1/statuses/:id" do
    test "soft-deletes own status, decrements counter", ctx do
      {:ok, s} =
        Statuses.create_local(ctx.alice, %{"status" => "hello", "visibility" => "public"})

      conn =
        ctx.conn
        |> auth(ctx.write)
        |> delete(~p"/api/v1/statuses/#{Integer.to_string(s.id)}")

      _ = json_response(conn, 200)

      reloaded = Angler.Repo.get!(Angler.Statuses.Status, s.id)
      assert reloaded.deleted_at

      author = Angler.Repo.get!(Angler.Profiles.Profile, ctx.alice.id)
      assert author.statuses_count == 0
    end

    test "403 for someone else's status", ctx do
      {:ok, %{profile: bob}} =
        Accounts.register(%{
          username: "bob",
          email: "bob@example.com",
          password: "passwordOK1"
        })

      {:ok, s} =
        Statuses.create_local(bob, %{"status" => "x", "visibility" => "public"})

      conn =
        ctx.conn
        |> auth(ctx.write)
        |> delete(~p"/api/v1/statuses/#{Integer.to_string(s.id)}")

      assert json_response(conn, 403)
    end

    test "404 for unknown id", ctx do
      conn = ctx.conn |> auth(ctx.write) |> delete(~p"/api/v1/statuses/9999999999")
      assert json_response(conn, 404)
    end
  end

  ## /context

  describe "GET /api/v1/statuses/:id/context" do
    test "returns ancestors + descendants of a thread", ctx do
      {:ok, root} =
        Statuses.create_local(ctx.alice, %{"status" => "root", "visibility" => "public"})

      {:ok, mid} =
        Statuses.create_local(ctx.alice, %{
          "status" => "mid",
          "visibility" => "public",
          "in_reply_to_id" => root.id
        })

      {:ok, leaf} =
        Statuses.create_local(ctx.alice, %{
          "status" => "leaf",
          "visibility" => "public",
          "in_reply_to_id" => mid.id
        })

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1/statuses/#{Integer.to_string(mid.id)}/context")
        |> json_response(200)

      assert [%{"id" => root_id_str}] = body["ancestors"]
      assert root_id_str == Integer.to_string(root.id)

      assert [%{"id" => leaf_id_str}] = body["descendants"]
      assert leaf_id_str == Integer.to_string(leaf.id)
    end

    test "404 when status is invisible to the viewer", ctx do
      {:ok, bob} = Profiles.create_profile(%{username: "bob"})

      {:ok, hidden} =
        Statuses.create_remote(%{
          profile_id: bob.id,
          visibility: :private,
          caption: "secret",
          rendered: "<p>secret</p>",
          type: "text",
          local: false,
          uri: "http://remote.test/notes/secret"
        })

      conn =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1/statuses/#{Integer.to_string(hidden.id)}/context")

      assert json_response(conn, 404)
    end
  end

  ## Pin / unpin

  describe "POST /api/v1/statuses/:id/pin and unpin" do
    test "pins own public status, then unpin", ctx do
      {:ok, s} =
        Statuses.create_local(ctx.alice, %{"status" => "x", "visibility" => "public"})

      conn =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1/statuses/#{Integer.to_string(s.id)}/pin")

      _ = json_response(conn, 200)

      [pinned] =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1/accounts/#{Integer.to_string(ctx.alice.id)}/pinned")
        |> json_response(200)

      assert pinned["id"] == Integer.to_string(s.id)

      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1/statuses/#{Integer.to_string(s.id)}/unpin")
        |> json_response(200)

      assert [] =
               ctx.conn
               |> auth(ctx.read)
               |> get(~p"/api/v1/accounts/#{Integer.to_string(ctx.alice.id)}/pinned")
               |> json_response(200)
    end

    test "rejects pinning someone else's status with 403", ctx do
      {:ok, %{profile: bob}} =
        Accounts.register(%{
          username: "bob",
          email: "bob@example.com",
          password: "passwordOK1"
        })

      {:ok, s} = Statuses.create_local(bob, %{"status" => "x", "visibility" => "public"})

      conn =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1/statuses/#{Integer.to_string(s.id)}/pin")

      assert json_response(conn, 403)
    end

    test "rejects pinning a private status with 422", ctx do
      {:ok, s} =
        Statuses.create_local(ctx.alice, %{"status" => "shh", "visibility" => "private"})

      conn =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1/statuses/#{Integer.to_string(s.id)}/pin")

      assert json_response(conn, 422)
    end
  end

  ## Push subscription

  describe "push subscription" do
    test "POST creates, GET reads, PUT updates alerts, DELETE removes", ctx do
      sub_body = %{
        "subscription" => %{
          "endpoint" => "https://push.example/abc",
          "keys" => %{"p256dh" => "p256-key", "auth" => "auth-key"}
        },
        "data" => %{
          "alerts" => %{"mention" => "true", "favourite" => "false"},
          "policy" => "all"
        }
      }

      created =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1/push/subscription", sub_body)
        |> json_response(200)

      assert created["endpoint"] == "https://push.example/abc"
      assert created["alerts"]["mention"] == true
      assert created["alerts"]["favourite"] == false

      # GET must use the same token the subscription is bound to.
      _ = ctx.conn |> auth(ctx.write) |> get(~p"/api/v1/push/subscription") |> json_response(200)

      updated =
        ctx.conn
        |> auth(ctx.write)
        |> put(~p"/api/v1/push/subscription", %{
          "data" => %{"alerts" => %{"mention" => "false", "follow" => "true"}}
        })
        |> json_response(200)

      assert updated["alerts"]["mention"] == false
      assert updated["alerts"]["follow"] == true

      assert %{} =
               ctx.conn
               |> auth(ctx.write)
               |> delete(~p"/api/v1/push/subscription")
               |> json_response(200)

      assert json_response(ctx.conn |> auth(ctx.write) |> get(~p"/api/v1/push/subscription"), 404)
    end
  end
end
