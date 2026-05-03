defmodule AnglerWeb.MastodonAPI.BootstrapTest do
  @moduledoc """
  Smoke-tests for the endpoints the Pixelfed/Mastodon mobile apps query
  during the post-login bootstrap. The shapes here matter — clients fail
  with "user info not available" when any of them 404 or return the wrong
  envelope.
  """

  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.Bookmarks
  alias Angler.Markers
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
    {:ok, %{access: write}} = OAuth.issue_token(user, client, scopes: ["write"])

    %{alice: alice, user: user, read: read, write: write}
  end

  defp auth(conn, t), do: put_req_header(conn, "authorization", "Bearer " <> t)

  describe "GET /api/v1/instance" do
    test "200 anonymous, has the canonical Mastodon fields", %{conn: conn} do
      body = json_response(get(conn, ~p"/api/v1/instance"), 200)

      assert is_binary(body["uri"])
      assert is_binary(body["title"])
      assert is_binary(body["version"])
      assert body["urls"]["streaming_api"] == nil
      assert is_map(body["stats"])
      assert is_integer(body["stats"]["user_count"])
      assert body["stats"]["user_count"] >= 1
      assert is_list(body["rules"])
      assert is_map(body["configuration"])
      assert body["configuration"]["statuses"]["max_characters"] > 0
    end
  end

  describe "GET /api/v2/instance" do
    test "200 anonymous, has v2 envelope with `domain`/`contact`/`registrations`", %{conn: conn} do
      body = json_response(get(conn, ~p"/api/v2/instance"), 200)

      assert is_binary(body["domain"])
      assert is_map(body["contact"])
      assert is_map(body["registrations"])
      assert is_map(body["configuration"]["urls"])
      assert is_map(body["thumbnail"])
    end
  end

  describe "GET /api/v1/instance/peers" do
    test "200 with []", %{conn: conn} do
      assert [] = json_response(get(conn, ~p"/api/v1/instance/peers"), 200)
    end
  end

  describe "GET /api/v1/preferences" do
    test "200 with the canonical 5 keys", ctx do
      body = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/preferences") |> json_response(200)

      assert body["posting:default:visibility"] == "public"
      assert body["posting:default:sensitive"] == false
      assert Map.has_key?(body, "posting:default:language")
      assert body["reading:expand:media"] == "default"
      assert body["reading:expand:spoilers"] == false
    end

    test "401 without bearer", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/v1/preferences"), 401)
    end
  end

  describe "markers" do
    test "GET returns rows the user has stored", ctx do
      {:ok, _} = Markers.set(ctx.alice.id, "home", 1234)
      {:ok, _} = Markers.set(ctx.alice.id, "notifications", 5678)

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1/markers?timeline[]=home&timeline[]=notifications")
        |> json_response(200)

      assert body["home"]["last_read_id"] == "1234"
      assert body["notifications"]["last_read_id"] == "5678"
      assert is_integer(body["home"]["version"])
    end

    test "POST sets and bumps version", ctx do
      first =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1/markers", %{"home" => %{"last_read_id" => "100"}})
        |> json_response(200)

      assert first["home"]["last_read_id"] == "100"

      second =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1/markers", %{"home" => %{"last_read_id" => "200"}})
        |> json_response(200)

      assert second["home"]["last_read_id"] == "200"
      assert second["home"]["version"] > first["home"]["version"]
    end
  end

  describe "favourites + bookmarks" do
    test "GET /favourites includes liked statuses", ctx do
      {:ok, %{profile: bob}} =
        Accounts.register(%{
          username: "bob",
          email: "bob@example.com",
          password: "passwordOK1"
        })

      {:ok, status} =
        Statuses.create_remote(%{
          profile_id: bob.id,
          visibility: :public,
          caption: "x",
          rendered: "<p>x</p>",
          type: "text",
          local: true,
          uri: nil
        })

      {:ok, _} = Statuses.favourite(ctx.alice, status)

      body = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/favourites") |> json_response(200)
      assert [s] = body
      assert s["id"] == Integer.to_string(status.id)
    end

    test "GET /bookmarks lists bookmarked statuses", ctx do
      {:ok, %{profile: bob}} =
        Accounts.register(%{
          username: "bob",
          email: "bob@example.com",
          password: "passwordOK1"
        })

      {:ok, status} =
        Statuses.create_remote(%{
          profile_id: bob.id,
          visibility: :public,
          caption: "x",
          rendered: "<p>x</p>",
          type: "text",
          local: true,
          uri: nil
        })

      {:ok, _} = Bookmarks.bookmark(ctx.alice.id, status.id)

      body = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/bookmarks") |> json_response(200)
      assert [s] = body
      assert s["id"] == Integer.to_string(status.id)
    end
  end

  describe "stub endpoints" do
    test "all return [] under :authenticated_read", ctx do
      for path <- [
            ~p"/api/v1/announcements",
            ~p"/api/v1/lists",
            ~p"/api/v1/endorsements",
            ~p"/api/v1/suggestions",
            ~p"/api/v1/filters",
            ~p"/api/v1/custom_emojis",
            ~p"/api/v2/filters",
            ~p"/api/v2/suggestions"
          ] do
        body = ctx.conn |> auth(ctx.read) |> get(path) |> json_response(200)
        assert body == [], "expected [] from #{path}"
      end
    end
  end
end
