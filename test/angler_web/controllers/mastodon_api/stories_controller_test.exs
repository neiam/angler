defmodule AnglerWeb.MastodonAPI.StoriesControllerTest do
  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.Follows
  alias Angler.OAuth
  alias Angler.Profiles
  alias Angler.Repo
  alias Angler.Stories
  alias Angler.Stories.Story

  @fixture Path.join([__DIR__, "..", "..", "..", "fixtures", "red.jpg"])

  setup do
    Application.put_env(:angler, :stories_enabled, true)
    on_exit(fn -> Application.delete_env(:angler, :stories_enabled) end)

    root =
      Path.join([System.tmp_dir!(), "ang-stories-test-#{System.unique_integer([:positive])}"])

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

  describe "carousel" do
    test "returns empty envelope when no stories", ctx do
      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.1/stories/carousel")
        |> json_response(200)

      assert body["self"] in [[], %{}]
      assert body["nodes"] == []
    end

    test "returns followed authors' active stories grouped by profile", ctx do
      {:ok, %{profile: bob}} =
        Accounts.register(%{
          username: "bob",
          email: "bob@example.com",
          password: "passwordOK1"
        })

      {:ok, :accepted, _} = Follows.follow(ctx.alice, bob)

      {:ok, draft} = Stories.add(bob, upload_fixture(), %{"duration" => 5})

      {:ok, _live} =
        Stories.publish(bob, draft.id, %{"can_reply" => "true", "can_react" => "true"})

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.1/stories/carousel")
        |> json_response(200)

      assert [node] = body["nodes"]
      assert node["user"]["username"] == "bob"
      assert [n] = node["nodes"]
      assert n["type"] == "photo"
    end
  end

  describe "self-carousel" do
    test "returns just the viewer's own active stories", ctx do
      {:ok, draft} = Stories.add(ctx.alice, upload_fixture())
      {:ok, _} = Stories.publish(ctx.alice, draft.id, %{})

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.1/stories/self-carousel")
        |> json_response(200)

      assert body["user"]["username"] == "alice" or body["user"]["username_acct"] == "alice"
      assert [_] = body["nodes"]
    end
  end

  describe "POST /add → /publish" do
    test "create a draft, then publish it", ctx do
      add_resp =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/stories/add", %{"file" => upload_fixture(), "duration" => "5"})
        |> json_response(200)

      assert add_resp["code"] == 200
      assert add_resp["media_type"] == "photo"
      media_id = add_resp["media_id"]

      pub =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/stories/publish", %{
          "media_id" => media_id,
          "duration" => "5",
          "can_reply" => "true",
          "can_react" => "true"
        })
        |> json_response(200)

      assert pub["code"] == 200

      story = Repo.get!(Story, String.to_integer(media_id))
      assert story.active
      assert story.expires_at
    end

    test "returns 422 when no file", ctx do
      assert json_response(
               ctx.conn |> auth(ctx.write) |> post(~p"/api/v1.1/stories/add"),
               422
             )
    end

    test "returns 503 when stories disabled", ctx do
      Application.put_env(:angler, :stories_enabled, false)

      assert json_response(
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1.1/stories/add", %{"file" => upload_fixture()}),
               503
             )
    end
  end

  describe "POST /seen" do
    test "follower marks story seen, increments view_count once", ctx do
      {:ok, %{profile: bob, user: bob_user}} =
        Accounts.register(%{
          username: "bob",
          email: "bob@example.com",
          password: "passwordOK1"
        })

      {:ok, draft} = Stories.add(bob, upload_fixture())
      {:ok, story} = Stories.publish(bob, draft.id, %{})

      {:ok, :accepted, _} = Follows.follow(ctx.alice, bob)

      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/stories/seen", %{"id" => Integer.to_string(story.id)})
        |> json_response(200)

      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/stories/seen", %{"id" => Integer.to_string(story.id)})
        |> json_response(200)

      reloaded = Repo.get!(Story, story.id)
      assert reloaded.view_count == 1

      _ = bob_user
    end

    test "non-follower → 403", ctx do
      {:ok, bob} = Profiles.create_profile(%{username: "bob"})
      {:ok, draft} = Stories.add(bob, upload_fixture())
      {:ok, story} = Stories.publish(bob, draft.id, %{})

      assert json_response(
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1.1/stories/seen", %{"id" => Integer.to_string(story.id)}),
               403
             )
    end
  end

  describe "POST /self-expire/:id" do
    test "owner marks own story inactive", ctx do
      {:ok, draft} = Stories.add(ctx.alice, upload_fixture())
      {:ok, story} = Stories.publish(ctx.alice, draft.id, %{})

      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/stories/self-expire/#{Integer.to_string(story.id)}")
        |> json_response(200)

      assert Repo.get!(Story, story.id).active == false
    end

    test "non-owner → 403", ctx do
      {:ok, bob} = Profiles.create_profile(%{username: "bob"})
      {:ok, draft} = Stories.add(bob, upload_fixture())
      {:ok, story} = Stories.publish(bob, draft.id, %{})

      assert json_response(
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1.1/stories/self-expire/#{Integer.to_string(story.id)}"),
               403
             )
    end
  end

  describe "POST /comment" do
    test "creates a :direct status to the author", ctx do
      {:ok, %{profile: bob}} =
        Accounts.register(%{
          username: "bob",
          email: "bob@example.com",
          password: "passwordOK1"
        })

      {:ok, draft} = Stories.add(bob, upload_fixture())
      {:ok, story} = Stories.publish(bob, draft.id, %{"can_reply" => "true"})

      comment = fn ->
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/stories/comment", %{
          "sid" => Integer.to_string(story.id),
          "caption" => "loved it"
        })
      end

      # Only followers may comment.
      assert json_response(comment.(), 404)
      {:ok, :accepted, _} = Angler.Follows.follow(ctx.alice, bob)

      body =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/stories/comment", %{
          "sid" => Integer.to_string(story.id),
          "caption" => "loved it"
        })
        |> json_response(200)

      assert body["code"] == 200

      sid = String.to_integer(body["id"])
      created = Repo.get!(Angler.Statuses.Status, sid)
      assert created.visibility == :direct
      assert created.caption =~ "loved it"
    end

    test "rejects when can_reply=false", ctx do
      {:ok, bob} = Profiles.create_profile(%{username: "bob"})
      {:ok, draft} = Stories.add(bob, upload_fixture())
      {:ok, story} = Stories.publish(bob, draft.id, %{"can_reply" => "false"})

      assert json_response(
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1.1/stories/comment", %{
                 "sid" => Integer.to_string(story.id),
                 "caption" => "hi"
               }),
               422
             )
    end
  end

  describe "expire worker" do
    test "Expire flips past-expiry stories to inactive", ctx do
      {:ok, draft} = Stories.add(ctx.alice, upload_fixture())
      {:ok, story} = Stories.publish(ctx.alice, draft.id, %{})

      story
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -10, :second))
      |> Repo.update!()

      assert :ok = perform_job(Angler.Stories.Workers.Expire, %{})
      refute Repo.get!(Story, story.id).active
    end
  end
end
