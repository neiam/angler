defmodule AnglerWeb.MastodonAPI.StoriesV12ControllerTest do
  @moduledoc """
  Coverage for `/api/v1.2/stories/...` — the v1.2 namespace covers
  `carouselNext`, `publishNext` (combined add+publish with overlays),
  and the mention-autocomplete prefix search.
  """

  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.Follows
  alias Angler.OAuth
  alias Angler.Repo
  alias Angler.Stories
  alias Angler.Stories.Story

  @fixture Path.join([__DIR__, "..", "..", "..", "fixtures", "red.jpg"])

  setup do
    Application.put_env(:angler, :stories_enabled, true)
    on_exit(fn -> Application.delete_env(:angler, :stories_enabled) end)

    root = Path.join([System.tmp_dir!(), "ang-v12-#{System.unique_integer([:positive])}"])
    File.mkdir_p!(root)
    Application.put_env(:angler, :media_root, root)

    on_exit(fn ->
      Application.delete_env(:angler, :media_root)
      File.rm_rf!(root)
    end)

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

  ## carousel-next

  describe "GET /api/v1.2/stories/carousel" do
    test "returns nodes-only envelope (no self block)", ctx do
      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.2/stories/carousel")
        |> json_response(200)

      assert body["nodes"] == []
      refute Map.has_key?(body, "self")
    end

    test "404 when stories disabled", ctx do
      Application.put_env(:angler, :stories_enabled, false)

      assert json_response(
               ctx.conn |> auth(ctx.read) |> get(~p"/api/v1.2/stories/carousel"),
               404
             )
    end
  end

  ## publish-next (combined add+publish)

  describe "POST /api/v1.2/stories/publish" do
    test "creates an active story with sanitized overlays", ctx do
      body =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.2/stories/publish", %{
          "image" => upload_fixture(),
          "overlays" => [
            %{
              "type" => "text",
              "content" => "Hello world!",
              "x" => 0.1,
              "y" => 0.2,
              "fontSize" => 24
            },
            %{"type" => "hashtag", "content" => "#elixir"}
          ]
        })
        |> json_response(200)

      assert body == %{"code" => 200, "msg" => "Successfully added"}

      [story] = Repo.all(Story)
      assert story.active
      assert length(story.overlays) == 2
      assert Enum.any?(story.overlays, &(&1["type"] == "text"))
      assert Enum.any?(story.overlays, &(&1["content"] == "#elixir"))
    end

    test "422 when image missing", ctx do
      assert json_response(
               ctx.conn |> auth(ctx.write) |> post(~p"/api/v1.2/stories/publish"),
               422
             )
    end

    test "422 when more than 4 overlays", ctx do
      five = Enum.map(1..5, fn _ -> %{"type" => "text", "content" => "x"} end)

      assert json_response(
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1.2/stories/publish", %{
                 "image" => upload_fixture(),
                 "overlays" => five
               }),
               422
             )
    end

    test "422 on invalid hashtag overlay", ctx do
      assert %{"errors" => errors} =
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1.2/stories/publish", %{
                 "image" => upload_fixture(),
                 "overlays" => [%{"type" => "hashtag", "content" => "no-leading-hash"}]
               })
               |> json_response(422)

      assert errors |> Map.keys() |> Enum.any?(&String.starts_with?(&1, "overlays.0"))
    end

    test "422 on non-https URL overlay", ctx do
      assert json_response(
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1.2/stories/publish", %{
                 "image" => upload_fixture(),
                 "overlays" => [%{"type" => "url", "content" => "http://example.com/"}]
               }),
               422
             )
    end

    test "422 on mention of someone who isn't a follower", ctx do
      {:ok, _} = Angler.Profiles.create_profile(%{username: "stranger"})

      assert json_response(
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1.2/stories/publish", %{
                 "image" => upload_fixture(),
                 "overlays" => [%{"type" => "mention", "content" => "@stranger"}]
               }),
               422
             )
    end

    test "200 when author already follows the mentioned user", ctx do
      {:ok, %{profile: bob}} =
        Accounts.register(%{
          username: "bob",
          email: "bob@example.com",
          password: "passwordOK1"
        })

      # Pixelfed only lets you mention users you yourself follow.
      {:ok, :accepted, _} = Follows.follow(ctx.alice, bob)

      assert %{"code" => 200} =
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1.2/stories/publish", %{
                 "image" => upload_fixture(),
                 "overlays" => [%{"type" => "mention", "content" => "@" <> bob.username}]
               })
               |> json_response(200)
    end

    test "404 when stories disabled", ctx do
      Application.put_env(:angler, :stories_enabled, false)

      assert json_response(
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1.2/stories/publish", %{"image" => upload_fixture()}),
               404
             )
    end
  end

  ## mention-autocomplete

  describe "GET /api/v1.2/stories/mention-autocomplete" do
    test "returns the viewer's followings whose username starts with the prefix", ctx do
      {:ok, %{profile: bob}} =
        Accounts.register(%{
          username: "bobby",
          email: "bob@example.com",
          password: "passwordOK1"
        })

      {:ok, %{profile: brenda}} =
        Accounts.register(%{
          username: "brenda",
          email: "brenda@example.com",
          password: "passwordOK1"
        })

      {:ok, _} =
        Accounts.register(%{
          username: "carol",
          email: "carol@example.com",
          password: "passwordOK1"
        })

      # Suggestions come from people the viewer (alice) follows.
      {:ok, :accepted, _} = Follows.follow(ctx.alice, bob)
      {:ok, :accepted, _} = Follows.follow(ctx.alice, brenda)

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.2/stories/mention-autocomplete?q=b")
        |> json_response(200)

      names = Enum.map(body, & &1["username"])
      assert "bobby" in names
      assert "brenda" in names
      refute "carol" in names
    end

    test "tolerates leading @", ctx do
      {:ok, %{profile: bob}} =
        Accounts.register(%{
          username: "bob",
          email: "bob@example.com",
          password: "passwordOK1"
        })

      {:ok, :accepted, _} = Follows.follow(ctx.alice, bob)

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.2/stories/mention-autocomplete?q=@b")
        |> json_response(200)

      assert Enum.any?(body, &(&1["username"] == "bob"))
    end

    test "422 when q empty", ctx do
      assert json_response(
               ctx.conn |> auth(ctx.read) |> get(~p"/api/v1.2/stories/mention-autocomplete"),
               422
             )
    end

    test "404 when stories disabled", ctx do
      Application.put_env(:angler, :stories_enabled, false)

      assert json_response(
               ctx.conn
               |> auth(ctx.read)
               |> get(~p"/api/v1.2/stories/mention-autocomplete?q=a"),
               404
             )
    end
  end

  ## render_node now includes overlays

  test "carousel surfaces overlays on rendered nodes", ctx do
    {:ok, %{profile: bob}} =
      Accounts.register(%{
        username: "bob",
        email: "bob@example.com",
        password: "passwordOK1"
      })

    {:ok, :accepted, _} = Follows.follow(ctx.alice, bob)

    {:ok, _story} =
      Stories.publish_next(bob, upload_fixture(), [
        %{"type" => "text", "content" => "hello", "x" => 0.5, "y" => 0.5}
      ])

    body =
      ctx.conn
      |> auth(ctx.read)
      |> get(~p"/api/v1.2/stories/carousel")
      |> json_response(200)

    assert [node] = body["nodes"]
    assert [n] = node["nodes"]
    assert is_list(n["overlays"])
    assert hd(n["overlays"])["type"] == "text"
  end
end
