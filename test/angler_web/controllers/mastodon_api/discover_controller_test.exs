defmodule AnglerWeb.MastodonAPI.DiscoverControllerTest do
  use AnglerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Angler.Accounts
  alias Angler.Follows
  alias Angler.Hashtags
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

    %{client: c} = OAuth.first_party_client!()
    {:ok, %{access: read}} = OAuth.issue_token(u, c, scopes: ["read"])

    %{alice: alice, read: read}
  end

  defp auth(conn, t), do: put_req_header(conn, "authorization", "Bearer " <> t)

  defp insert_photo!(profile, opts \\ []) do
    {:ok, s} =
      Statuses.create_remote(%{
        profile_id: profile.id,
        visibility: opts[:visibility] || :public,
        caption: opts[:caption] || "x",
        rendered: "<p>x</p>",
        type: opts[:type] || "photo",
        local: opts[:local] || true,
        is_nsfw: opts[:nsfw] || false,
        uri: "http://remote.test/notes/#{System.unique_integer([:positive])}"
      })

    s
  end

  ## /api/v1/discover/posts

  describe "GET /api/v1/discover/posts" do
    test "returns photo/video public posts the viewer doesn't follow", ctx do
      {:ok, bob} = Profiles.create_profile(%{username: "bob"})
      _photo = insert_photo!(bob)

      body = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/discover/posts") |> json_response(200)

      assert is_list(body["posts"])
      assert length(body["posts"]) >= 1
    end

    test "excludes text-only posts", ctx do
      {:ok, bob} = Profiles.create_profile(%{username: "bob"})

      {:ok, _text_only} =
        Statuses.create_remote(%{
          profile_id: bob.id,
          visibility: :public,
          caption: "just words",
          rendered: "<p>just words</p>",
          type: "text",
          local: true,
          uri: "http://remote.test/notes/text"
        })

      body = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/discover/posts") |> json_response(200)
      assert body["posts"] == []
    end

    test "excludes nsfw and non-public", ctx do
      {:ok, bob} = Profiles.create_profile(%{username: "bob"})
      _ = insert_photo!(bob, nsfw: true)
      _ = insert_photo!(bob, visibility: :private)

      body = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/discover/posts") |> json_response(200)
      assert body["posts"] == []
    end
  end

  ## /api/v1.1/discover/accounts/popular

  describe "GET /api/v1.1/discover/accounts/popular" do
    test "ranks by followers_count, excludes viewer + follows", ctx do
      {:ok, bob} = Profiles.create_profile(%{username: "bob"})
      {:ok, carol} = Profiles.create_profile(%{username: "carol"})
      {:ok, dan} = Profiles.create_profile(%{username: "dan"})

      Angler.Repo.update!(Ecto.Changeset.change(bob, followers_count: 100))
      Angler.Repo.update!(Ecto.Changeset.change(carol, followers_count: 50))
      Angler.Repo.update!(Ecto.Changeset.change(dan, followers_count: 25))

      {:ok, :accepted, _} = Follows.follow(ctx.alice, carol)

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.1/discover/accounts/popular")
        |> json_response(200)

      usernames = Enum.map(body, & &1["username"])
      assert "bob" in usernames
      assert "dan" in usernames
      refute "carol" in usernames
      refute "alice" in usernames
    end

    test "excludes locked accounts", ctx do
      {:ok, locked} = Profiles.create_profile(%{username: "locked", is_private: true})
      Angler.Repo.update!(Ecto.Changeset.change(locked, followers_count: 999))

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.1/discover/accounts/popular")
        |> json_response(200)

      refute Enum.any?(body, &(&1["username"] == "locked"))
    end
  end

  ## /api/v1.1/discover/posts/trending

  describe "GET /api/v1.1/discover/posts/trending" do
    test "ranks by likes_count within range", ctx do
      {:ok, bob} = Profiles.create_profile(%{username: "bob"})
      hot = insert_photo!(bob, caption: "hot")
      cold = insert_photo!(bob, caption: "cold")

      Statuses.inc_counter(hot.id, :likes_count, 100)
      Statuses.inc_counter(cold.id, :likes_count, 1)

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.1/discover/posts/trending?range=monthly")
        |> json_response(200)

      [first | _] = body
      assert first["id"] == Integer.to_string(hot.id)
    end

    test "honors range=daily by skipping older posts", ctx do
      {:ok, bob} = Profiles.create_profile(%{username: "bob"})
      old = insert_photo!(bob)
      Statuses.inc_counter(old.id, :likes_count, 100)

      # Push the post past the daily cutoff.
      Angler.Repo.update_all(
        from(s in Angler.Statuses.Status, where: s.id == ^old.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)]
      )

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.1/discover/posts/trending?range=daily")
        |> json_response(200)

      assert body == []
    end
  end

  ## /api/v1.1/discover/posts/hashtags

  describe "GET /api/v1.1/discover/posts/hashtags" do
    test "returns trending hashtags from the last 7 days", ctx do
      Hashtags.ensure!("photography")

      {:ok, bob} = Profiles.create_profile(%{username: "bob"})

      {:ok, _} =
        Statuses.create_local(bob, %{
          "status" => "love this #photography",
          "visibility" => "public"
        })

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.1/discover/posts/hashtags")
        |> json_response(200)

      assert [hit | _] = body
      assert hit["name"] == "#photography"
      assert hit["hashtag"] == "photography"
      assert hit["total"] >= 1
    end
  end

  describe "GET /api/v1.1/discover/posts/network/trending" do
    test "always []", ctx do
      assert [] =
               ctx.conn
               |> auth(ctx.read)
               |> get(~p"/api/v1.1/discover/posts/network/trending")
               |> json_response(200)
    end
  end
end
