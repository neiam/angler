defmodule Angler.Federation.RemoteAvatarTest do
  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Federation.Actor
  alias Angler.Federation.Workers.{ActorRefresh, RemoteAvatarFetch}
  alias Angler.Profiles.Profile

  @actor "http://remote.test/users/bob"
  @avatar "http://remote.test/media/bob.jpg"
  @jpeg File.read!(Path.join([__DIR__, "..", "..", "fixtures", "red.jpg"]))

  setup do
    root =
      Path.join(System.tmp_dir!(), "angler-avatar-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    Application.put_env(:angler, :media_root, root)
    Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})

    on_exit(fn ->
      Application.delete_env(:angler, :media_root)
      Application.delete_env(:angler, :req_options)
      File.rm_rf!(root)
    end)

    :ok
  end

  defp actor_doc(icon) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => @actor,
      "type" => "Person",
      "preferredUsername" => "bob",
      "inbox" => @actor <> "/inbox",
      "icon" => icon,
      "image" => %{"type" => "Image", "url" => "http://remote.test/media/header.png"}
    }
  end

  defp serve(doc) do
    Req.Test.stub(:angler_http, fn conn ->
      case conn.request_path do
        "/users/bob" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/activity+json")
          |> Plug.Conn.send_resp(200, Jason.encode!(doc))

        "/media/bob.jpg" ->
          conn |> Plug.Conn.put_resp_content_type("image/jpeg") |> Plug.Conn.send_resp(200, @jpeg)

        _ ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  test "a new remote profile shows the actor's icon and queues a local copy" do
    serve(actor_doc(%{"type" => "Image", "mediaType" => "image/jpeg", "url" => @avatar}))

    assert {:ok, %Profile{} = bob} = Actor.resolve(@actor)
    assert bob.avatar_path == @avatar
    assert bob.avatar_remote_url == @avatar
    assert bob.header_path == "http://remote.test/media/header.png"

    assert_enqueued(worker: RemoteAvatarFetch, args: %{"kind" => "avatar", "url" => @avatar})
    assert_enqueued(worker: RemoteAvatarFetch, args: %{"kind" => "header"})

    assert :ok =
             perform_job(RemoteAvatarFetch, %{profile_id: bob.id, kind: "avatar", url: @avatar})

    stored = Repo.get!(Profile, bob.id)
    assert stored.avatar_path =~ "/storage/"
    assert stored.avatar_remote_url == @avatar
  end

  test "a refresh keeps the local copy while the icon is unchanged" do
    serve(actor_doc(%{"type" => "Image", "url" => @avatar}))
    {:ok, bob} = Actor.resolve(@actor)
    :ok = perform_job(RemoteAvatarFetch, %{profile_id: bob.id, kind: "avatar", url: @avatar})
    local = Repo.get!(Profile, bob.id).avatar_path

    Repo.delete_all(Oban.Job)
    {:ok, _} = Actor.refresh(@actor)

    assert Repo.get!(Profile, bob.id).avatar_path == local
    refute_enqueued(worker: RemoteAvatarFetch, args: %{"kind" => "avatar"})
  end

  test "icon url as a Link list, and non-http urls ignored" do
    serve(actor_doc(%{"type" => "Image", "url" => [%{"type" => "Link", "href" => @avatar}]}))
    assert {:ok, %Profile{avatar_path: @avatar}} = Actor.resolve(@actor)

    serve(actor_doc(%{"type" => "Image", "url" => "data:image/png;base64,AAAA"}))
    {:ok, bob} = Actor.refresh(@actor)
    assert bob.avatar_path == nil
  end

  test "bytes that aren't an image are dropped and the origin url stays" do
    serve(actor_doc(%{"type" => "Image", "url" => @avatar}))
    {:ok, bob} = Actor.resolve(@actor)

    Req.Test.stub(:angler_http, fn conn -> Plug.Conn.send_resp(conn, 200, "<html>nope</html>") end)

    assert :ok =
             perform_job(RemoteAvatarFetch, %{profile_id: bob.id, kind: "avatar", url: @avatar})

    assert Repo.get!(Profile, bob.id).avatar_path == @avatar
  end

  test "with REMOTE_AVATARS off the origin url is used and nothing is downloaded" do
    Application.put_env(:angler, :remote_avatars, false)
    on_exit(fn -> Application.delete_env(:angler, :remote_avatars) end)

    serve(actor_doc(%{"type" => "Image", "url" => @avatar}))
    assert {:ok, %Profile{avatar_path: @avatar}} = Actor.resolve(@actor)
    refute_enqueued(worker: RemoteAvatarFetch)
  end

  test "resolving a stale cached profile queues a background refresh" do
    serve(actor_doc(nil))
    {:ok, bob} = Actor.resolve(@actor)
    refute_enqueued(worker: ActorRefresh)

    old = DateTime.add(DateTime.utc_now(), -4 * 86_400)
    bob |> Ecto.Changeset.change(last_fetched_at: old) |> Repo.update!()

    {:ok, _} = Actor.resolve(@actor)
    assert_enqueued(worker: ActorRefresh, args: %{"actor_url" => @actor})
  end
end
