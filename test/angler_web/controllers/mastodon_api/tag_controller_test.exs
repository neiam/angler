defmodule AnglerWeb.MastodonAPI.TagControllerTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.Hashtags
  alias Angler.Hashtags.Following
  alias Angler.OAuth

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

    %{alice: alice, write: write, read: read}
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  describe "GET /api/v1/tags/:id" do
    test "200 with following:false for an unknown tag (no 404)", ctx do
      conn = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/tags/neverseen")
      body = json_response(conn, 200)

      assert body["name"] == "neverseen"
      assert body["following"] == false
      assert body["history"] == []
    end

    test "reflects an existing follow", ctx do
      {:ok, _} = Following.follow(ctx.alice, "photography")

      conn = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/tags/Photography")
      assert json_response(conn, 200)["following"] == true
    end

    test "includes post count when _pe is set (mobile header), omits it otherwise", ctx do
      # pixelfed-rn always requests with `?_pe=1` and reads `hashtag.count`.
      with_pe = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/tags/neverseen?_pe=1")
      assert json_response(with_pe, 200)["count"] == 0

      without = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/tags/neverseen")
      refute Map.has_key?(json_response(without, 200), "count")
    end
  end

  describe "POST /api/v1/tags/:id/follow + /unfollow" do
    test "follow then unfollow toggles state and persists", ctx do
      follow = ctx.conn |> auth(ctx.write) |> post(~p"/api/v1/tags/nature/follow")
      assert json_response(follow, 200)["following"] == true

      tag = Hashtags.get_by_name("nature")
      assert Following.following?(ctx.alice.id, tag.id)

      unfollow = ctx.conn |> auth(ctx.write) |> post(~p"/api/v1/tags/nature/unfollow")
      assert json_response(unfollow, 200)["following"] == false
      refute Following.following?(ctx.alice.id, tag.id)
    end

    test "follow is idempotent", ctx do
      ctx.conn |> auth(ctx.write) |> post(~p"/api/v1/tags/nature/follow")
      ctx.conn |> auth(ctx.write) |> post(~p"/api/v1/tags/nature/follow")
      assert Following.count(ctx.alice.id) == 1
    end

    test "422 once the 25-tag cap is reached", ctx do
      for n <- 1..25, do: {:ok, _} = Following.follow(ctx.alice, "tag#{n}")

      conn = ctx.conn |> auth(ctx.write) |> post(~p"/api/v1/tags/onemore/follow")
      assert json_response(conn, 422)["error"] =~ "25"
      refute Hashtags.get_by_name("onemore") && Following.count(ctx.alice.id) > 25

      # Re-following an already-followed tag at the cap still succeeds (idempotent).
      conn2 = ctx.conn |> auth(ctx.write) |> post(~p"/api/v1/tags/tag1/follow")
      assert json_response(conn2, 200)["following"] == true
    end
  end

  describe "GET /api/v1/followed_tags" do
    test "lists followed tags as a bare array", ctx do
      {:ok, _} = Following.follow(ctx.alice, "art")
      {:ok, _} = Following.follow(ctx.alice, "film")

      conn = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/followed_tags")
      body = json_response(conn, 200)

      assert is_list(body)
      assert MapSet.new(body, & &1["name"]) == MapSet.new(["art", "film"])
      assert Enum.all?(body, &(&1["following"] == true))
    end
  end
end
