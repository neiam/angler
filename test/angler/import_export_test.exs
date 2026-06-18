defmodule Angler.ImportExportTest do
  use Angler.DataCase, async: false

  alias Angler.Export.AccountArchive
  alias Angler.Import.Mastodon
  alias Angler.Profiles
  alias Angler.Statuses

  defp local!(u) do
    {:ok, p} = Profiles.create_profile(%{username: u})
    p
  end

  defp post!(profile, text) do
    {:ok, s} = Statuses.create_local(profile, %{"status" => text}, broadcast: false)
    s
  end

  describe "AccountArchive.build/2" do
    test "writes a zip with actor, outbox and posts json" do
      alice = local!("alice")
      post!(alice, "first post #hello")
      post!(alice, "second post")

      dir = Path.join(System.tmp_dir!(), "exp-#{System.unique_integer([:positive])}")
      assert {:ok, summary} = AccountArchive.build(alice, dir: dir)
      assert summary.count == 2
      assert File.regular?(summary.path)

      {:ok, entries} = :zip.unzip(String.to_charlist(summary.path), [:memory])
      names = Map.new(entries, fn {name, body} -> {to_string(name), body} end)

      assert Map.has_key?(names, "actor.json")
      assert Map.has_key?(names, "outbox.json")
      assert Map.has_key?(names, "posts.json")

      outbox = Jason.decode!(names["outbox.json"])
      assert outbox["type"] == "OrderedCollection"
      assert outbox["totalItems"] == 2
      assert [%{"type" => "Create", "object" => %{"type" => "Note"}} | _] = outbox["orderedItems"]

      File.rm_rf(dir)
    end

    test "rejects remote profiles" do
      {:ok, remote} =
        Profiles.create_profile(%{
          username: "bob",
          domain: "remote.test",
          remote_url: "http://remote.test/users/bob",
          inbox_url: "http://remote.test/users/bob/inbox",
          public_key_pem: "stub"
        })

      assert {:error, :not_local_profile} = AccountArchive.build(remote)
    end
  end

  describe "Mastodon.import_dir/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), "masto-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    defp write_outbox!(dir, notes) do
      outbox = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "OrderedCollection",
        "orderedItems" =>
          Enum.map(notes, fn note ->
            %{"type" => "Create", "object" => note}
          end)
      }

      File.write!(Path.join(dir, "outbox.json"), Jason.encode!(outbox))
    end

    test "creates backdated posts from an outbox", %{dir: dir} do
      profile = local!("importer")

      write_outbox!(dir, [
        %{
          "type" => "Note",
          "content" => "<p>Hello from <b>2019</b> #throwback</p>",
          "published" => "2019-05-01T12:00:00Z",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        },
        %{
          "type" => "Note",
          "content" => "<p>another one</p>",
          "published" => "2019-05-02T12:00:00Z",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      ])

      assert {:ok, summary} = Mastodon.import_dir(profile, dir)
      assert summary.posts == 2
      assert summary.imported == 2
      assert summary.failed == 0

      posts = Statuses.list_for_export(profile.id)
      assert length(posts) == 2

      first = hd(posts)
      assert first.caption =~ "Hello from 2019"
      # HTML stripped, entities resolved, hashtag preserved as text
      refute first.caption =~ "<b>"
      assert first.inserted_at.year == 2019
      assert first.visibility == :public
    end

    test "is idempotent — re-import skips existing", %{dir: dir} do
      profile = local!("importer")

      write_outbox!(dir, [
        %{
          "type" => "Note",
          "content" => "<p>solo</p>",
          "published" => "2018-01-01T00:00:00Z",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      ])

      assert {:ok, %{imported: 1}} = Mastodon.import_dir(profile, dir)
      assert {:ok, %{imported: 0, skipped: 1}} = Mastodon.import_dir(profile, dir)
    end

    test "missing outbox is an error", %{dir: dir} do
      profile = local!("importer")
      assert {:error, :no_outbox_file} = Mastodon.import_dir(profile, dir)
    end
  end
end
