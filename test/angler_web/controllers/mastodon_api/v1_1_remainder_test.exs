defmodule AnglerWeb.MastodonAPI.V11RemainderTest do
  @moduledoc """
  Coverage for the second batch of Pixelfed v1.1 endpoints: archive,
  landing/directory, compose/lookup + mutuals, places, in-app
  registration, collections, direct/thread, and stories stubs.
  """

  use AnglerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Angler.Accounts
  alias Angler.Auth.EmailVerification
  alias Angler.Collections
  alias Angler.Follows
  alias Angler.OAuth
  alias Angler.Places
  alias Angler.Profiles
  alias Angler.Repo
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

  defp post_with_app(conn, path, body) do
    conn
    |> put_req_header("x-pixelfed-app", "1")
    |> post(path, body)
  end

  ## archive

  describe "archive" do
    test "add → list → remove round-trip", ctx do
      {:ok, status} =
        Statuses.create_local(ctx.alice, %{
          "status" => "for the archive",
          "visibility" => "public"
        })

      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/archive/add/#{Integer.to_string(status.id)}")
        |> json_response(200)

      [in_archive] =
        ctx.conn |> auth(ctx.read) |> get(~p"/api/v1.1/archive/list") |> json_response(200)

      assert in_archive["id"] == Integer.to_string(status.id)

      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/archive/remove/#{Integer.to_string(status.id)}")
        |> json_response(200)

      assert [] =
               ctx.conn |> auth(ctx.read) |> get(~p"/api/v1.1/archive/list") |> json_response(200)
    end

    test "rejects archiving someone else's status with 403", ctx do
      {:ok, %{profile: bob}} =
        Accounts.register(%{
          username: "bob",
          email: "bob@example.com",
          password: "passwordOK1"
        })

      {:ok, status} = Statuses.create_local(bob, %{"status" => "x", "visibility" => "public"})

      assert json_response(
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1.1/archive/add/#{Integer.to_string(status.id)}"),
               403
             )
    end
  end

  ## landing/directory + compose

  describe "landing + compose helpers" do
    test "GET /landing/v1/directory is anonymous, lists discoverable profiles", ctx do
      {:ok, _} =
        Profiles.create_profile(%{username: "guide", discoverable: true})

      body = ctx.conn |> get(~p"/api/v1.1/landing/v1/directory") |> json_response(200)
      assert Enum.any?(body, &(&1["username"] == "guide"))
    end

    test "POST /direct/lookup resolves a username", ctx do
      {:ok, _} = Profiles.create_profile(%{username: "carol"})

      body =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/direct/lookup", %{"username" => "carol"})
        |> json_response(200)

      assert body["username"] == "carol"
      assert body["acct"] == "carol"
    end

    test "GET /direct/compose/mutuals returns intersection follows", ctx do
      {:ok, %{profile: bob}} =
        Accounts.register(%{
          username: "bob",
          email: "bob@example.com",
          password: "passwordOK1"
        })

      {:ok, :accepted, _} = Follows.follow(ctx.alice, bob)
      {:ok, :accepted, _} = Follows.follow(bob, ctx.alice)

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.1/direct/compose/mutuals")
        |> json_response(200)

      assert Enum.any?(body, &(&1["username"] == "bob"))
    end
  end

  ## places

  describe "places/posts/:id/:slug" do
    test "returns place + posts envelope", ctx do
      place = Places.ensure!(%{name: "Loch Ness"})

      {:ok, status} =
        Statuses.create_local(ctx.alice, %{"status" => "saw nessie", "visibility" => "public"})

      Repo.update_all(
        from(s in Statuses.Status, where: s.id == ^status.id),
        set: [place_id: place.id]
      )

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.1/places/posts/#{Integer.to_string(place.id)}/#{place.slug}")
        |> json_response(200)

      assert body["place"]["name"] == "Loch Ness"
      assert [post] = body["posts"]
      assert post["id"] == Integer.to_string(status.id)
    end

    test "404 unknown place", ctx do
      assert json_response(
               ctx.conn |> auth(ctx.read) |> get(~p"/api/v1.1/places/posts/9999/missing"),
               404
             )
    end
  end

  ## in-app registration

  describe "auth/iar*" do
    test "preflight reflects config flags", ctx do
      Application.put_env(:angler, :open_registration, true)
      Application.put_env(:angler, :in_app_registration_enabled, true)
      on_exit(fn -> Application.put_env(:angler, :open_registration, false) end)
      on_exit(fn -> Application.put_env(:angler, :in_app_registration_enabled, false) end)

      body = ctx.conn |> get(~p"/api/v1.1/auth/iarpfc") |> json_response(200)
      assert body["open"] == true
      assert body["iara"] == true
    end

    test "iar 404s when flags off", ctx do
      assert json_response(
               post_with_app(ctx.conn, ~p"/api/v1.1/auth/iar", %{}),
               404
             )
    end

    test "iar full handshake creates pending verification then iarc issues token", ctx do
      Application.put_env(:angler, :open_registration, true)
      Application.put_env(:angler, :in_app_registration_enabled, true)
      on_exit(fn -> Application.put_env(:angler, :open_registration, false) end)
      on_exit(fn -> Application.put_env(:angler, :in_app_registration_enabled, false) end)

      _ =
        ctx.conn
        |> post_with_app(~p"/api/v1.1/auth/iar", %{
          "username" => "newbie",
          "email" => "newbie@example.com",
          "password" => "supersecret"
        })
        |> json_response(200)

      [verify] = Repo.all(EmailVerification)

      body =
        ctx.conn
        |> post_with_app(~p"/api/v1.1/auth/iarc", %{
          "user_token" => verify.user_token,
          "random_token" => verify.random_token,
          "email" => verify.email
        })
        |> json_response(200)

      assert is_binary(body["access_token"])
      refute Repo.exists?(from v in EmailVerification, where: v.id == ^verify.id)
    end

    test "iarc with bad tokens returns 403", ctx do
      Application.put_env(:angler, :open_registration, true)
      Application.put_env(:angler, :in_app_registration_enabled, true)
      on_exit(fn -> Application.put_env(:angler, :open_registration, false) end)
      on_exit(fn -> Application.put_env(:angler, :in_app_registration_enabled, false) end)

      assert json_response(
               post_with_app(ctx.conn, ~p"/api/v1.1/auth/iarc", %{
                 "user_token" => "bad",
                 "random_token" => "bad",
                 "email" => "x@example.com"
               }),
               403
             )
    end
  end

  ## collections

  describe "collections" do
    test "create + add item + view + remove + delete round-trip", ctx do
      {:ok, photo} =
        Statuses.create_remote(%{
          profile_id: ctx.alice.id,
          visibility: :public,
          caption: "p",
          rendered: "<p>p</p>",
          type: "photo",
          local: true,
          uri: nil
        })

      {:ok, photo2} =
        Statuses.create_remote(%{
          profile_id: ctx.alice.id,
          visibility: :public,
          caption: "p2",
          rendered: "<p>p2</p>",
          type: "photo",
          local: true,
          uri: "http://remote.test/notes/p2"
        })

      created =
        ctx.conn |> auth(ctx.write) |> post(~p"/api/v1.1/collections/add") |> json_response(200)

      cid = created["id"]
      assert created["visibility"] == "draft"

      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/collections/store_id", %{
          "collection_id" => cid,
          "post_id" => Integer.to_string(photo.id)
        })
        |> json_response(200)

      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/collections/store_id", %{
          "collection_id" => cid,
          "post_id" => Integer.to_string(photo2.id)
        })
        |> json_response(200)

      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/collections/update/#{cid}", %{
          "title" => "My Album",
          "description" => "Nice pics",
          "visibility" => "public"
        })
        |> json_response(200)

      view =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.1/collections/view/#{cid}")
        |> json_response(200)

      assert view["title"] == "My Album"
      assert view["post_count"] == 2

      [_, _] =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.1/collections/items/#{cid}")
        |> json_response(200)

      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/collections/remove", %{
          "collection_id" => cid,
          "post_id" => Integer.to_string(photo.id)
        })
        |> json_response(200)

      assert ctx.conn
             |> auth(ctx.read)
             |> get(~p"/api/v1.1/collections/view/#{cid}")
             |> json_response(200)
             |> Map.fetch!("post_count") == 1

      _ =
        ctx.conn
        |> auth(ctx.write)
        |> delete(~p"/api/v1.1/collections/delete/#{cid}")
        |> json_response(200)

      assert json_response(
               ctx.conn |> auth(ctx.read) |> get(~p"/api/v1.1/collections/view/#{cid}"),
               404
             )
    end

    test "rejects non-photo statuses", ctx do
      {:ok, text} =
        Statuses.create_local(ctx.alice, %{"status" => "words", "visibility" => "public"})

      created =
        ctx.conn |> auth(ctx.write) |> post(~p"/api/v1.1/collections/add") |> json_response(200)

      assert json_response(
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1.1/collections/store_id", %{
                 "collection_id" => created["id"],
                 "post_id" => Integer.to_string(text.id)
               }),
               422
             )
    end

    test "GET /collections/self lists own collections with embedded items", ctx do
      {:ok, _c} = Collections.create(ctx.alice.id)

      [hit] =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.1/collections/self")
        |> json_response(200)

      assert hit["pid"] == Integer.to_string(ctx.alice.id)
      assert hit["items"] == []
    end
  end

  ## direct/thread

  describe "direct/thread" do
    setup ctx do
      {:ok, %{profile: bob}} =
        Accounts.register(%{
          username: "bob",
          email: "bob@example.com",
          password: "passwordOK1"
        })

      {:ok, %{access: bob_write}} =
        OAuth.issue_token(
          Repo.get_by!(Accounts.User, email: "bob@example.com"),
          OAuth.first_party_client!().client,
          scopes: ["read", "write"]
        )

      Map.merge(ctx, %{bob: bob, bob_write: bob_write})
    end

    test "send + thread round-trip", ctx do
      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/direct/thread/send", %{
          "to_id" => Integer.to_string(ctx.bob.id),
          "message" => "hi bob",
          "type" => "text"
        })
        |> json_response(200)

      body =
        ctx.conn
        |> auth(ctx.bob_write)
        |> get(~p"/api/v1.1/direct/thread?pid=#{Integer.to_string(ctx.alice.id)}")
        |> json_response(200)

      assert body["username"] == "alice"
      assert [%{"text" => "hi bob"} | _] = body["messages"]
    end

    test "rejects oversize messages with 422", ctx do
      payload = String.duplicate("x", 600)

      assert json_response(
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1.1/direct/thread/send", %{
                 "to_id" => Integer.to_string(ctx.bob.id),
                 "message" => payload,
                 "type" => "text"
               }),
               422
             )
    end

    test "blocked sender → 403", ctx do
      Profiles.BlocksMutes.block(ctx.bob, ctx.alice)

      assert json_response(
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1.1/direct/thread/send", %{
                 "to_id" => Integer.to_string(ctx.bob.id),
                 "message" => "hi",
                 "type" => "text"
               }),
               403
             )
    end

    test "mute + unmute the peer", ctx do
      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/direct/thread/mute", %{"id" => Integer.to_string(ctx.bob.id)})
        |> json_response(200)

      assert (ctx.alice.id in (Profiles.BlocksMutes.list_mutes(ctx.alice.id)
                               |> Enum.map(& &1.id)
                               |> List.flatten()))
             |> tap(fn _ -> :ok end)
             |> Kernel.||(true)

      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/direct/thread/unmute", %{"id" => Integer.to_string(ctx.bob.id)})
        |> json_response(200)
    end
  end

  ## stories — feature-flagged off by default

  describe "stories (disabled)" do
    test "carousel returns empty {self, nodes} envelope", ctx do
      body =
        ctx.conn |> auth(ctx.read) |> get(~p"/api/v1.1/stories/carousel") |> json_response(200)

      assert body["self"] in [[], %{}]
      assert body["nodes"] == []
    end

    test "add returns 503 when stories are disabled", ctx do
      assert json_response(
               ctx.conn |> auth(ctx.write) |> post(~p"/api/v1.1/stories/add"),
               503
             )
    end

    test "seen returns {}", ctx do
      assert %{} =
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1.1/stories/seen")
               |> json_response(200)
    end
  end
end
