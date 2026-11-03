defmodule Angler.Statuses.FederationTest do
  use Angler.DataCase, async: false

  alias Angler.Profiles
  alias Angler.Statuses
  alias Angler.Statuses.{Federation, Status}

  setup do
    {:ok, alice} = Profiles.create_profile(%{username: "alice"})

    {:ok, bob} =
      Profiles.create_profile(%{
        username: "bob",
        domain: "remote.test",
        remote_url: "http://remote.test/users/bob",
        inbox_url: "http://remote.test/users/bob/inbox",
        public_key_pem: "stub"
      })

    %{alice: alice, bob: bob}
  end

  defp create_note(uri, opts \\ []) do
    %{
      "type" => "Create",
      "id" => uri <> "/activity",
      "actor" => Keyword.get(opts, :actor, "http://remote.test/users/bob"),
      "object" =>
        Map.merge(
          %{
            "type" => "Note",
            "id" => uri,
            "attributedTo" => Keyword.get(opts, :actor, "http://remote.test/users/bob"),
            "url" => uri,
            "content" => Keyword.get(opts, :content, "<p>hello world</p>"),
            "to" => Keyword.get(opts, :to, ["https://www.w3.org/ns/activitystreams#Public"]),
            "cc" => Keyword.get(opts, :cc, []),
            "sensitive" => Keyword.get(opts, :sensitive, false),
            "summary" => Keyword.get(opts, :summary, nil)
          },
          Keyword.get(opts, :extra_object, %{})
        )
    }
  end

  describe "handle_create/2" do
    test "a reply to a post we don't have stays a reply, and is adopted when it arrives",
         ctx do
      parent_uri = "http://remote.test/notes/parent"
      reply_uri = "http://remote.test/notes/orphan"

      reply = create_note(reply_uri, extra_object: %{"inReplyTo" => parent_uri})
      assert :ok = Federation.handle_create(reply, ctx.bob.remote_url)

      orphan = Statuses.get_by_uri(reply_uri)
      assert orphan.in_reply_to_id == nil
      assert orphan.in_reply_to_uri == parent_uri
      assert Status.reply?(orphan)

      cursor = Angler.Pagination.MastodonCursor.parse(%{}, 20, 40)
      assert {[], _} = Angler.Timelines.public(cursor)

      photo = %{
        "attachment" => [
          %{
            "type" => "Document",
            "mediaType" => "image/jpeg",
            "url" => "http://remote.test/p.jpg"
          }
        ]
      }

      assert :ok =
               Federation.handle_create(
                 create_note(parent_uri, extra_object: photo),
                 ctx.bob.remote_url
               )

      parent = Statuses.get_by_uri(parent_uri)

      assert Statuses.get_by_uri(reply_uri).in_reply_to_id == parent.id
      assert parent.reply_count == 1
      assert {[%Status{id: id}], _} = Angler.Timelines.public(cursor)
      assert id == parent.id
    end

    test "materializes a remote Note as a public Status", ctx do
      uri = "http://remote.test/notes/1"
      assert :ok = Federation.handle_create(create_note(uri), ctx.bob.remote_url)

      status = Statuses.get_by_uri(uri)
      assert status
      assert status.profile_id == ctx.bob.id
      assert status.visibility == :public
      assert status.local == false
      assert status.rendered == "<p>hello world</p>"
      assert status.caption == "hello world"
    end

    test "is idempotent on re-delivery", ctx do
      uri = "http://remote.test/notes/2"
      assert :ok = Federation.handle_create(create_note(uri), ctx.bob.remote_url)
      assert :ok = Federation.handle_create(create_note(uri), ctx.bob.remote_url)
      assert Repo.aggregate(Status, :count) == 1
    end

    test "derives :unlisted when public is in cc only", ctx do
      uri = "http://remote.test/notes/3"

      activity =
        create_note(uri,
          to: ["http://remote.test/users/bob/followers"],
          cc: ["https://www.w3.org/ns/activitystreams#Public"]
        )

      assert :ok = Federation.handle_create(activity, ctx.bob.remote_url)
      assert %Status{visibility: :unlisted} = Statuses.get_by_uri(uri)
    end

    test "followers-only with a mention is :private, not a DM", ctx do
      uri = "http://remote.test/notes/fo"

      activity =
        create_note(uri,
          to: ["http://remote.test/users/bob/followers"],
          cc: ["http://localhost/users/alice"]
        )

      assert :ok = Federation.handle_create(activity, ctx.bob.remote_url)
      assert %Status{visibility: :private} = Statuses.get_by_uri(uri)
    end

    test "only mentions is :direct, and so is no audience at all", ctx do
      dm = "http://remote.test/notes/dm"
      bare = "http://remote.test/notes/bare"

      :ok =
        Federation.handle_create(
          create_note(dm, to: ["http://localhost/users/alice"]),
          ctx.bob.remote_url
        )

      :ok = Federation.handle_create(create_note(bare, to: []), ctx.bob.remote_url)

      assert %Status{visibility: :direct} = Statuses.get_by_uri(dm)
      assert %Status{visibility: :direct} = Statuses.get_by_uri(bare)
    end

    test "extracts hashtags from object.tag", ctx do
      uri = "http://remote.test/notes/4"

      activity =
        create_note(uri,
          extra_object: %{
            "tag" => [
              %{"type" => "Hashtag", "name" => "#photography", "href" => "x"},
              %{"type" => "Hashtag", "name" => "Sunsets", "href" => "y"}
            ]
          }
        )

      assert :ok = Federation.handle_create(activity, ctx.bob.remote_url)

      status = Statuses.get_by_uri(uri) |> Repo.preload(status_hashtags: :hashtag)
      tag_names = Enum.map(status.status_hashtags, & &1.hashtag.name) |> Enum.sort()
      assert tag_names == ["photography", "sunsets"]
    end

    test "extracts local mentions from object.tag", ctx do
      uri = "http://remote.test/notes/5"
      alice_url = AnglerWeb.Endpoint.url() <> "/users/alice"

      activity =
        create_note(uri,
          extra_object: %{
            "tag" => [
              %{"type" => "Mention", "name" => "@alice", "href" => alice_url}
            ]
          }
        )

      assert :ok = Federation.handle_create(activity, ctx.bob.remote_url)

      status = Statuses.get_by_uri(uri) |> Repo.preload(:mentions)
      assert [mention] = status.mentions
      assert mention.profile_id == ctx.alice.id
    end

    test "increments the author's statuses_count", ctx do
      uri = "http://remote.test/notes/6"
      assert :ok = Federation.handle_create(create_note(uri), ctx.bob.remote_url)

      assert Repo.get!(Angler.Profiles.Profile, ctx.bob.id).statuses_count == 1
    end
  end

  describe "remote media attachments" do
    test "a mix of photos and videos is a photo:video:album, as upstream", ctx do
      uri = "http://remote.test/notes/mixed"
      att = &%{"type" => "Document", "mediaType" => &1, "url" => "http://remote.test/" <> &2}

      activity =
        create_note(uri,
          extra_object: %{
            "attachment" => [att.("image/jpeg", "a.jpg"), att.("video/mp4", "b.mp4")]
          }
        )

      assert :ok = Federation.handle_create(activity, ctx.bob.remote_url)
      assert %Status{type: "photo:video:album"} = Statuses.get_by_uri(uri)
    end

    test "ingests AP attachments as remote assets the API renders by origin URL", ctx do
      uri = "http://remote.test/notes/media-1"

      img = "http://remote.test/storage/pic.jpg"

      activity =
        create_note(uri,
          extra_object: %{
            "attachment" => [
              %{
                "type" => "Document",
                "mediaType" => "image/jpeg",
                "url" => img,
                "name" => "a cat",
                "blurhash" => "UU",
                "width" => 1080,
                "height" => 1350
              }
            ]
          }
        )

      assert :ok = Federation.handle_create(activity, ctx.bob.remote_url)

      status = Statuses.get_by_uri(uri) |> Repo.preload(:media_attachments)
      assert [asset] = status.media_attachments
      assert asset.storage == "remote"
      assert asset.remote_url == img
      assert asset.media_type == "image/jpeg"
      assert asset.caption == "a cat"
      assert status.type in ["photo", "photo:album"]

      rendered = AnglerWeb.MastodonAPI.Media.render(asset)
      assert rendered["url"] == img
      assert rendered["preview_url"] == img
      assert rendered["remote_url"] == img
    end

    test "skips attachments lacking a usable url/type", ctx do
      uri = "http://remote.test/notes/media-2"

      activity =
        create_note(uri,
          extra_object: %{"attachment" => [%{"type" => "Document", "name" => "no url"}]}
        )

      assert :ok = Federation.handle_create(activity, ctx.bob.remote_url)
      status = Statuses.get_by_uri(uri) |> Repo.preload(:media_attachments)
      assert status.media_attachments == []
    end
  end

  describe "handle_delete_tombstone/2" do
    test "soft-deletes a previously-mirrored status", ctx do
      uri = "http://remote.test/notes/del"
      :ok = Federation.handle_create(create_note(uri), ctx.bob.remote_url)

      assert :ok = Federation.handle_delete_tombstone(uri, ctx.bob.remote_url)
      assert is_nil(Statuses.get_by_uri(uri))

      raw = Repo.one(from s in Status, where: s.uri == ^uri, select: s.deleted_at)
      assert raw
    end

    test "is a no-op for unknown uri" do
      assert :ok =
               Federation.handle_delete_tombstone(
                 "http://nope/missing",
                 "http://remote.test/users/bob"
               )
    end
  end
end
