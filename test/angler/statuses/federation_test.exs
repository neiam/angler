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

  describe "handle_delete_tombstone/1" do
    test "soft-deletes a previously-mirrored status", ctx do
      uri = "http://remote.test/notes/del"
      :ok = Federation.handle_create(create_note(uri), ctx.bob.remote_url)

      assert :ok = Federation.handle_delete_tombstone(uri)
      assert is_nil(Statuses.get_by_uri(uri))

      raw = Repo.one(from s in Status, where: s.uri == ^uri, select: s.deleted_at)
      assert raw
    end

    test "is a no-op for unknown uri" do
      assert :ok = Federation.handle_delete_tombstone("http://nope/missing")
    end
  end
end
