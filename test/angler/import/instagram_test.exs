defmodule Angler.Import.InstagramTest do
  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Import.Instagram
  alias Angler.Profiles
  alias Angler.Repo
  alias Angler.Snowflake
  alias Angler.Statuses.Status

  @fixture Path.join([__DIR__, "..", "..", "fixtures", "red.jpg"])

  # A fixed 2020 instant (after the snowflake epoch) shared by both posts so we
  # exercise same-second collision handling.
  @ts 1_577_900_000

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
    %{alice: alice}
  end

  # Builds an extracted-export directory with two single-media posts sharing the
  # same creation timestamp but distinct image bytes.
  defp build_export do
    dir = Path.join(System.tmp_dir!(), "angler-ig-export-#{System.unique_integer([:positive])}")
    media_dir = Path.join(dir, "media/posts/202001")
    File.mkdir_p!(media_dir)

    File.cp!(@fixture, Path.join(media_dir, "a.jpg"))
    # Distinct bytes (still a valid JPEG header) so dedup doesn't collapse them.
    File.write!(Path.join(media_dir, "b.jpg"), File.read!(@fixture) <> <<0, 1, 2, 3>>)

    posts = [
      %{
        "creation_timestamp" => @ts,
        "title" => "",
        # Mojibake: UTF-8 "Café" bytes decoded as Latin-1, as Instagram writes it.
        "media" => [%{"uri" => "media/posts/202001/a.jpg", "title" => "CafÃ©"}]
      },
      %{
        "creation_timestamp" => @ts,
        "title" => "second post",
        "media" => [%{"uri" => "media/posts/202001/b.jpg"}]
      }
    ]

    File.write!(Path.join(dir, "posts_1.json"), Jason.encode!(posts))
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "imports posts backdated to their Instagram timestamp with media attached", ctx do
    dir = build_export()

    assert {:ok, summary} = Instagram.import_dir(ctx.alice, dir)
    assert summary.posts == 2
    assert summary.imported == 2
    assert summary.skipped == 0
    assert summary.failed == 0

    statuses =
      Status
      |> Repo.all()
      |> Repo.preload(:media_attachments)
      |> Enum.sort_by(& &1.id)

    assert length(statuses) == 2

    for s <- statuses do
      # Snowflake id and inserted_at both encode the original instant.
      assert Snowflake.timestamp(s.id) == @ts * 1000
      assert DateTime.to_unix(s.inserted_at, :millisecond) == @ts * 1000
      assert [_one] = s.media_attachments
      assert s.local
    end

    # Same-second posts still get distinct ids.
    assert Enum.map(statuses, & &1.id) |> Enum.uniq() |> length() == 2

    # Caption pulled from the lone media entry and mojibake-corrected.
    captions = Enum.map(statuses, & &1.caption)
    assert "Café" in captions
    assert "second post" in captions
  end

  test "re-running the import is idempotent", ctx do
    dir = build_export()

    assert {:ok, %{imported: 2}} = Instagram.import_dir(ctx.alice, dir)
    assert {:ok, second} = Instagram.import_dir(ctx.alice, dir)

    assert second.imported == 0
    assert second.skipped == 2
    assert Repo.aggregate(Status, :count) == 2
  end

  test "dry run reports counts without writing", ctx do
    dir = build_export()

    assert {:ok, summary} = Instagram.import_dir(ctx.alice, dir, dry_run: true)
    assert summary.imported == 2
    assert Repo.aggregate(Status, :count) == 0
  end

  test "import_zip extracts and imports", ctx do
    dir = build_export()
    zip_path = Path.join(System.tmp_dir!(), "ig-#{System.unique_integer([:positive])}.zip")

    # Zip the export contents (entries relative to the export root).
    files =
      Path.wildcard(Path.join(dir, "**/*"))
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&{String.to_charlist(Path.relative_to(&1, dir)), File.read!(&1)})

    {:ok, _} = :zip.create(String.to_charlist(zip_path), files)
    on_exit(fn -> File.rm_rf!(zip_path) end)

    assert {:ok, %{imported: 2}} = Instagram.import_zip(ctx.alice, zip_path)
    assert Repo.aggregate(Status, :count) == 2
  end
end
