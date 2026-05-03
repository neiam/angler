defmodule Angler.MediaTest do
  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Media
  alias Angler.Media.Asset
  alias Angler.Profiles

  @fixture Path.join([__DIR__, "..", "fixtures", "red.jpg"])
  @video_fixture Path.join([__DIR__, "..", "fixtures", "red.mp4"])

  setup do
    root =
      Path.join([System.tmp_dir!(), "angler-media-test-#{System.unique_integer([:positive])}"])

    File.mkdir_p!(root)
    Application.put_env(:angler, :media_root, root)

    on_exit(fn ->
      Application.delete_env(:angler, :media_root)
      File.rm_rf!(root)
    end)

    {:ok, alice} = Profiles.create_profile(%{username: "alice"})
    %{alice: alice, root: root}
  end

  defp upload_fixture do
    src = Path.join(System.tmp_dir!(), "angler-test-#{System.unique_integer([:positive])}.jpg")
    File.cp!(@fixture, src)
    %Plug.Upload{path: src, filename: "red.jpg", content_type: "image/jpeg"}
  end

  describe "upload/3" do
    test "stores a JPEG, inserts pending row, enqueues processing", ctx do
      assert {:ok, %Asset{} = asset} = Media.upload(ctx.alice, upload_fixture())

      assert asset.status == "pending"
      assert asset.media_type == "image/jpeg"
      assert asset.path_original
      assert asset.profile_id == ctx.alice.id

      assert_enqueued(worker: Angler.Media.Workers.ImageProcess, args: %{"asset_id" => asset.id})

      stored = Path.join(ctx.root, asset.path_original)
      assert File.exists?(stored)
    end

    test "deduplicates by (profile, sha256)", ctx do
      {:ok, a} = Media.upload(ctx.alice, upload_fixture())
      {:ok, b} = Media.upload(ctx.alice, upload_fixture())
      assert a.id == b.id
    end

    test "accepts MP4 video upload", ctx do
      src = Path.join(System.tmp_dir!(), "ang-mp4-#{System.unique_integer([:positive])}.mp4")
      File.cp!(@video_fixture, src)

      upload = %Plug.Upload{path: src, filename: "red.mp4", content_type: "video/mp4"}

      assert {:ok, %Asset{} = asset} = Media.upload(ctx.alice, upload)
      assert asset.media_type == "video/mp4"

      drain = Oban.drain_queue(queue: :media)
      assert drain.failure == 0

      reloaded = Repo.get!(Asset, asset.id)
      assert reloaded.status == "ready"
      assert reloaded.width == 64
      assert reloaded.height == 48
      assert reloaded.duration_ms in 900..1100
      assert reloaded.path_preview =~ "_poster.jpg"
    end

    test "rejects non-image MIME", ctx do
      txt = Path.join(System.tmp_dir!(), "angler-test-#{System.unique_integer([:positive])}.txt")
      File.write!(txt, "hello")

      assert {:error, :unsupported_type} =
               Media.upload(ctx.alice, %Plug.Upload{
                 path: txt,
                 filename: "x.txt",
                 content_type: "text/plain"
               })
    end
  end

  describe "ImageProcess worker" do
    test "transitions pending → ready with width/height/blurhash", ctx do
      {:ok, asset} = Media.upload(ctx.alice, upload_fixture())

      drain = Oban.drain_queue(queue: :media)
      assert drain.failure == 0

      reloaded = Repo.get!(Asset, asset.id)
      assert reloaded.status == "ready"
      assert reloaded.width == 64
      assert reloaded.height == 64
      assert is_binary(reloaded.blurhash)
      assert reloaded.path_thumb
      assert reloaded.path_preview
    end
  end

  describe "attach_to_status/3" do
    test "attaches owned, unattached assets", ctx do
      {:ok, asset} = Media.upload(ctx.alice, upload_fixture())

      {:ok, status} =
        Angler.Statuses.create_remote(%{
          profile_id: ctx.alice.id,
          visibility: :public,
          caption: "x",
          rendered: "<p>x</p>",
          type: "text",
          local: true,
          uri: nil
        })

      assert {:ok, [_]} = Media.attach_to_status([asset.id], status.id, ctx.alice.id)

      assert %Asset{status_id: sid} = Repo.get!(Asset, asset.id)
      assert sid == status.id
    end

    test "rejects another user's media", ctx do
      {:ok, bob} = Profiles.create_profile(%{username: "bob"})
      {:ok, asset} = Media.upload(bob, upload_fixture())

      {:ok, status} =
        Angler.Statuses.create_remote(%{
          profile_id: ctx.alice.id,
          visibility: :public,
          caption: "x",
          rendered: "<p>x</p>",
          type: "text",
          local: true,
          uri: nil
        })

      assert {:error, :unattachable} = Media.attach_to_status([asset.id], status.id, ctx.alice.id)
    end
  end

  describe "Statuses.create_local with media_ids" do
    test "attaches media and sets type=photo", ctx do
      {:ok, asset} = Media.upload(ctx.alice, upload_fixture())

      {:ok, status} =
        Angler.Statuses.create_local(ctx.alice, %{
          "status" => "look at this",
          "visibility" => "public",
          "media_ids" => [Integer.to_string(asset.id)]
        })

      assert status.type == "photo"
      reloaded = Repo.get!(Asset, asset.id)
      assert reloaded.status_id == status.id
    end

    test "permits empty caption when media is attached", ctx do
      {:ok, asset} = Media.upload(ctx.alice, upload_fixture())

      assert {:ok, _} =
               Angler.Statuses.create_local(ctx.alice, %{
                 "status" => "",
                 "media_ids" => [asset.id]
               })
    end

    test "still rejects empty caption with no media", ctx do
      assert {:error, :empty_status} =
               Angler.Statuses.create_local(ctx.alice, %{"status" => ""})
    end
  end
end
