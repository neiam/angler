defmodule AnglerWeb.MastodonAPI.SpecCompletionTest do
  @moduledoc """
  Coverage for the slice that closes out Mastodon-spec gaps: lists, filters,
  tag follow, domain blocks, announcements, featured tags, and the
  Mastodon-shape /reports endpoint.
  """

  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.Announcements
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
    {:ok, %{access: write}} = OAuth.issue_token(u, c, scopes: ["write"])

    %{alice: alice, user: u, read: read, write: write}
  end

  defp auth(conn, t), do: put_req_header(conn, "authorization", "Bearer " <> t)

  ## Lists

  describe "lists" do
    test "POST + GET + members + timeline + DELETE round-trip", ctx do
      {:ok, %{profile: bob}} =
        Accounts.register(%{
          username: "bob",
          email: "bob@example.com",
          password: "passwordOK1"
        })

      {:ok, :accepted, _} = Follows.follow(ctx.alice, bob)

      created =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1/lists", %{"title" => "Friends"})
        |> json_response(200)

      list_id = created["id"]
      assert created["title"] == "Friends"

      [in_index] = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/lists") |> json_response(200)
      assert in_index["id"] == list_id

      ctx.conn
      |> auth(ctx.write)
      |> post(~p"/api/v1/lists/#{list_id}/accounts", %{
        "account_ids" => [Integer.to_string(bob.id)]
      })
      |> json_response(200)

      [member] =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1/lists/#{list_id}/accounts")
        |> json_response(200)

      assert member["username"] == "bob"

      {:ok, _} = Statuses.create_local(bob, %{"status" => "from bob", "visibility" => "public"})

      [tl] =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1/timelines/list/#{list_id}")
        |> json_response(200)

      assert tl["content"] =~ "from bob"

      ctx.conn
      |> auth(ctx.write)
      |> delete(~p"/api/v1/lists/#{list_id}")
      |> json_response(200)

      assert [] = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/lists") |> json_response(200)
    end

    test "add_accounts silently skips non-followed targets", ctx do
      {:ok, stranger} = Profiles.create_profile(%{username: "stranger"})

      list =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1/lists", %{"title" => "x"})
        |> json_response(200)

      ctx.conn
      |> auth(ctx.write)
      |> post(~p"/api/v1/lists/#{list["id"]}/accounts", %{
        "account_ids" => [Integer.to_string(stranger.id)]
      })
      |> json_response(200)

      assert [] =
               ctx.conn
               |> auth(ctx.read)
               |> get(~p"/api/v1/lists/#{list["id"]}/accounts")
               |> json_response(200)
    end
  end

  ## Filters

  describe "filters" do
    test "v2 CRUD round-trip", ctx do
      created =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v2/filters", %{
          "title" => "no-spoilers",
          "context" => ["home", "public"],
          "filter_action" => "warn",
          "keywords_attributes" => [
            %{"keyword" => "spoiler", "whole_word" => true},
            %{"keyword" => "leak"}
          ]
        })
        |> json_response(200)

      assert created["title"] == "no-spoilers"
      assert length(created["keywords"]) == 2

      [in_list] = ctx.conn |> auth(ctx.read) |> get(~p"/api/v2/filters") |> json_response(200)
      assert in_list["id"] == created["id"]

      updated =
        ctx.conn
        |> auth(ctx.write)
        |> put(~p"/api/v2/filters/#{created["id"]}", %{"title" => "renamed"})
        |> json_response(200)

      assert updated["title"] == "renamed"

      ctx.conn
      |> auth(ctx.write)
      |> delete(~p"/api/v2/filters/#{created["id"]}")
      |> json_response(200)

      assert [] = ctx.conn |> auth(ctx.read) |> get(~p"/api/v2/filters") |> json_response(200)
    end

    test "v1 endpoint emits flattened (filter, keyword) rows", ctx do
      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v2/filters", %{
          "title" => "x",
          "context" => ["home"],
          "keywords_attributes" => [%{"keyword" => "a"}, %{"keyword" => "b"}]
        })

      assert [_, _] = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/filters") |> json_response(200)
    end
  end

  ## Tag follow

  describe "tag follow" do
    test "follow → followed_tags lists it; unfollow removes", ctx do
      Hashtags.ensure!("photography")

      followed =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1/tags/photography/follow")
        |> json_response(200)

      assert followed["following"] == true

      [hit] =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1/followed_tags")
        |> json_response(200)

      assert hit["name"] == "photography"

      ctx.conn
      |> auth(ctx.write)
      |> post(~p"/api/v1/tags/photography/unfollow")
      |> json_response(200)

      assert [] =
               ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/followed_tags") |> json_response(200)
    end

    test "GET /tags/:id 200 with following=false for an unfollowed tag", ctx do
      Hashtags.ensure!("travel")

      body =
        ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/tags/travel") |> json_response(200)

      assert body["name"] == "travel"
      assert body["following"] == false
    end
  end

  ## Domain blocks

  describe "domain_blocks" do
    test "POST adds, GET lists, DELETE removes", ctx do
      ctx.conn
      |> auth(ctx.write)
      |> post(~p"/api/v1/domain_blocks", %{"domain" => "spam.example"})
      |> json_response(200)

      assert ["spam.example"] =
               ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/domain_blocks") |> json_response(200)

      ctx.conn
      |> auth(ctx.write)
      |> delete(~p"/api/v1/domain_blocks?domain=spam.example")
      |> json_response(200)

      assert [] =
               ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/domain_blocks") |> json_response(200)
    end
  end

  ## Announcements

  describe "announcements" do
    test "lists published announcements; dismiss removes from results", ctx do
      {:ok, ann} =
        Announcements.create(%{
          "text" => "Hello world",
          "published" => true,
          "published_at" => DateTime.utc_now()
        })

      [in_list] =
        ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/announcements") |> json_response(200)

      assert in_list["content"] == "Hello world"

      ctx.conn
      |> auth(ctx.write)
      |> post(~p"/api/v1/announcements/#{Integer.to_string(ann.id)}/dismiss")
      |> json_response(200)

      assert [] =
               ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/announcements") |> json_response(200)
    end
  end

  ## Featured tags

  describe "featured_tags" do
    test "POST + GET own + GET account + DELETE", ctx do
      Hashtags.ensure!("hiking")

      created =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1/featured_tags", %{"name" => "hiking"})
        |> json_response(200)

      [own] = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/featured_tags") |> json_response(200)
      assert own["name"] == "hiking"

      [public] =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1/accounts/#{Integer.to_string(ctx.alice.id)}/featured_tags")
        |> json_response(200)

      assert public["name"] == "hiking"

      ctx.conn
      |> auth(ctx.write)
      |> delete(~p"/api/v1/featured_tags/#{created["id"]}")
      |> json_response(200)

      assert [] =
               ctx.conn |> auth(ctx.read) |> get(~p"/api/v1/featured_tags") |> json_response(200)
    end
  end

  ## /api/v1/reports

  describe "/reports" do
    test "POST creates a report with Mastodon shape", ctx do
      {:ok, target} = Profiles.create_profile(%{username: "spammy"})

      body =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1/reports", %{
          "account_id" => Integer.to_string(target.id),
          "category" => "spam",
          "comment" => "spam spam"
        })
        |> json_response(200)

      assert body["category"] == "spam"
      assert body["target_account"]["username"] == "spammy"
    end

    test "self-report returns 422", ctx do
      body =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1/reports", %{
          "account_id" => Integer.to_string(ctx.alice.id),
          "category" => "spam"
        })
        |> json_response(422)

      assert body["error"] =~ "self"
    end
  end
end
