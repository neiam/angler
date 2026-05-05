defmodule AnglerWeb.MastodonAPI.PixelfedV1MirrorTest do
  @moduledoc """
  Smoke tests for the `/api/pixelfed/v1/...` mirror namespace plus the
  three endpoints that were missing in v1.1: `compose/search/location`,
  `directory/listing`, and `stories/viewers`.
  """

  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.OAuth
  alias Angler.Places
  alias Angler.Profiles
  alias Angler.Stories

  @fixture Path.join([__DIR__, "..", "..", "..", "fixtures", "red.jpg"])

  setup do
    {:ok, %{user: u, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: c} = OAuth.first_party_client!()
    {:ok, %{access: read}} = OAuth.issue_token(u, c, scopes: ["read"])
    {:ok, %{access: write}} = OAuth.issue_token(u, c, scopes: ["write"])

    %{alice: alice, read: read, write: write}
  end

  defp auth(conn, t), do: put_req_header(conn, "authorization", "Bearer " <> t)

  defp upload_fixture do
    src = Path.join(System.tmp_dir!(), "story-#{System.unique_integer([:positive])}.jpg")
    File.cp!(@fixture, src)
    %Plug.Upload{path: src, filename: "red.jpg", content_type: "image/jpeg"}
  end

  ## compose/search/location

  describe "GET /compose/search/location" do
    test "matches places by name (ILIKE), bounded", ctx do
      _ = Places.ensure!(%{name: "Berlin", country: "DE"})
      _ = Places.ensure!(%{name: "Berlin Hauptbahnhof", country: "DE"})
      _ = Places.ensure!(%{name: "Paris", country: "FR"})

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.1/compose/search/location?q=berlin")
        |> json_response(200)

      names = Enum.map(body, & &1["name"])
      assert "Berlin" in names
      assert "Berlin Hauptbahnhof" in names
      refute "Paris" in names
    end

    test "422 when q is missing", ctx do
      assert json_response(
               ctx.conn |> auth(ctx.read) |> get(~p"/api/v1.1/compose/search/location"),
               422
             )
    end

    test "available on the pixelfed/v1 mirror", ctx do
      _ = Places.ensure!(%{name: "Tokyo"})

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/pixelfed/v1/compose/search/location?q=tok")
        |> json_response(200)

      assert Enum.any?(body, &(&1["name"] == "Tokyo"))
    end
  end

  ## directory/listing

  describe "GET /directory/listing" do
    test "404 when no submission key is configured", %{conn: conn} do
      Application.delete_env(:angler, :pixelfed_directory_sk)

      assert json_response(get(conn, ~p"/api/v1.1/directory/listing?sk=anything"), 404)
      assert json_response(get(conn, ~p"/api/pixelfed/v1/directory/listing?sk=anything"), 404)
    end

    test "404 when sk param is missing even though configured", %{conn: conn} do
      Application.put_env(:angler, :pixelfed_directory_sk, "secret-token")
      on_exit(fn -> Application.delete_env(:angler, :pixelfed_directory_sk) end)

      assert json_response(get(conn, ~p"/api/v1.1/directory/listing"), 404)
    end

    test "403 when sk does not match", %{conn: conn} do
      Application.put_env(:angler, :pixelfed_directory_sk, "secret-token")
      on_exit(fn -> Application.delete_env(:angler, :pixelfed_directory_sk) end)

      assert json_response(get(conn, ~p"/api/v1.1/directory/listing?sk=wrong"), 403)
    end

    test "200 returns instance metadata when sk matches", %{conn: conn} do
      Application.put_env(:angler, :pixelfed_directory_sk, "secret-token")
      Application.put_env(:angler, :pixelfed_directory, %{summary: "Hi", admin: nil})

      on_exit(fn ->
        Application.delete_env(:angler, :pixelfed_directory_sk)
        Application.delete_env(:angler, :pixelfed_directory)
      end)

      body =
        get(conn, ~p"/api/pixelfed/v1/directory/listing?sk=secret-token")
        |> json_response(200)

      assert body["_sk"] == "secret-token"
      assert body["summary"] == "Hi"
      assert is_binary(body["_domain"])
      assert is_binary(body["_ts"])
    end
  end

  ## stories/viewers

  describe "GET /stories/viewers" do
    setup do
      Application.put_env(:angler, :stories_enabled, true)

      root =
        Path.join([System.tmp_dir!(), "ang-mirror-test-#{System.unique_integer([:positive])}"])

      File.mkdir_p!(root)
      Application.put_env(:angler, :media_root, root)

      on_exit(fn ->
        Application.delete_env(:angler, :stories_enabled)
        Application.delete_env(:angler, :media_root)
        File.rm_rf!(root)
      end)

      :ok
    end

    test "owner sees who viewed; non-owners get 403", ctx do
      {:ok, draft} = Stories.add(ctx.alice, upload_fixture())
      {:ok, story} = Stories.publish(ctx.alice, draft.id, %{})

      {:ok, %{user: bob_user, profile: bob}} =
        Accounts.register(%{
          username: "bob",
          email: "bob@example.com",
          password: "passwordOK1"
        })

      {:ok, :accepted, _} = Angler.Follows.follow(bob, ctx.alice)
      {:ok, _} = Stories.mark_seen(bob, story.id)

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/pixelfed/v1/stories/viewers?sid=#{Integer.to_string(story.id)}")
        |> json_response(200)

      assert [v] = body["viewers"]
      assert v["username"] == "bob"
      assert is_binary(v["seen_at"])

      %{client: c2} = OAuth.first_party_client!()
      {:ok, %{access: bob_read}} = OAuth.issue_token(bob_user, c2, scopes: ["read"])

      assert json_response(
               ctx.conn
               |> auth(bob_read)
               |> get(~p"/api/pixelfed/v1/stories/viewers?sid=#{Integer.to_string(story.id)}"),
               403
             )
    end

    test "empty envelope when stories disabled", ctx do
      Application.put_env(:angler, :stories_enabled, false)

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/pixelfed/v1/stories/viewers?sid=1")
        |> json_response(200)

      assert body == %{"viewers" => [], "next_max_id" => nil}
    end
  end

  ## generic mirror smoke

  describe "pixelfed/v1 mirror" do
    test "GET /accounts/:id/posts works through the mirror", ctx do
      {:ok, _} = Profiles.create_profile(%{username: "stranger"})

      assert json_response(
               ctx.conn
               |> auth(ctx.read)
               |> get(~p"/api/pixelfed/v1/accounts/#{Integer.to_string(ctx.alice.id)}/posts"),
               200
             )
    end

    test "GET /web/settings works through the mirror", ctx do
      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/pixelfed/v1/web/settings")
        |> json_response(200)

      assert is_map(body) or is_list(body)
    end

    test "GET /stories/carousel works through the mirror", ctx do
      Application.put_env(:angler, :stories_enabled, true)
      on_exit(fn -> Application.delete_env(:angler, :stories_enabled) end)

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/pixelfed/v1/stories/carousel")
        |> json_response(200)

      assert is_map(body)
      assert Map.has_key?(body, "self")
      assert Map.has_key?(body, "nodes")
    end
  end
end
