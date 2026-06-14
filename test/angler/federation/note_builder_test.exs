defmodule Angler.Federation.NoteBuilderTest do
  use Angler.DataCase, async: false

  alias Angler.Federation.NoteBuilder
  alias Angler.Media.Asset
  alias Angler.Profiles
  alias Angler.Statuses
  alias Angler.Statuses.OutboundAudience
  alias Angler.Statuses.Status

  defp local!(username) do
    {:ok, p} = Profiles.create_profile(%{username: username})
    p
  end

  defp remote!(username) do
    {:ok, p} =
      Profiles.create_profile(%{
        username: username,
        domain: "remote.test",
        remote_url: "http://remote.test/users/#{username}",
        inbox_url: "http://remote.test/users/#{username}/inbox",
        public_key_pem: "stub"
      })

    p
  end

  defp remote_status!(profile, uri) do
    Status.changeset(%{
      profile_id: profile.id,
      local: false,
      uri: uri,
      url: uri,
      visibility: :public,
      scope: "public",
      caption: "parent",
      rendered: "<p>parent</p>",
      type: "text"
    })
    |> Repo.insert!()
  end

  test "object/1 emits a public Note addressed to followers" do
    alice = local!("alice")
    {:ok, status} = Statuses.create_local(alice, %{"status" => "hello fedi"})

    obj = NoteBuilder.object(status)

    assert obj["type"] == "Note"
    assert obj["id"] == status.uri
    assert obj["content"] =~ "hello fedi"
    assert "https://www.w3.org/ns/activitystreams#Public" in obj["to"]
    assert Enum.any?(obj["cc"], &String.ends_with?(&1, "/followers"))
    assert obj["attachment"] == []
  end

  test "includes media attachments with absolute URLs (regression: was always [])" do
    alice = local!("alice")
    {:ok, status} = Statuses.create_local(alice, %{"status" => "with pic"})

    Repo.insert!(
      Asset.changeset(%{
        profile_id: alice.id,
        status_id: status.id,
        media_type: "image/jpeg",
        storage: "local",
        status: "ready",
        path_original: "#{alice.id}/orig.jpg",
        caption: "a view",
        width: 800,
        height: 600
      })
    )

    obj = NoteBuilder.object(status)

    assert [att] = obj["attachment"]
    assert att["type"] == "Document"
    assert att["mediaType"] == "image/jpeg"
    assert att["name"] == "a view"
    assert att["width"] == 800
    assert String.starts_with?(att["url"], "http")
    assert att["url"] =~ "orig.jpg"
  end

  test "create_activity wraps the Note and strips the embedded @context" do
    alice = local!("alice")
    {:ok, status} = Statuses.create_local(alice, %{"status" => "yo"})

    activity = NoteBuilder.create_activity(status, alice)

    assert activity["type"] == "Create"
    assert activity["id"] == status.uri <> "/activity"
    assert activity["object"]["type"] == "Note"
    refute Map.has_key?(activity["object"], "@context")
    assert activity["@context"]
  end

  describe "replies" do
    test "emit inReplyTo, and address + mention the (remote) parent author" do
      alice = local!("alice")
      bob = remote!("bob")
      parent = remote_status!(bob, "http://remote.test/notes/1")

      {:ok, reply} =
        Statuses.create_local(alice, %{"status" => "nice shot", "in_reply_to_id" => parent.id})

      obj = NoteBuilder.object(reply)

      assert obj["inReplyTo"] == parent.uri
      assert bob.remote_url in obj["cc"]

      assert Enum.any?(obj["tag"], fn t ->
               t["type"] == "Mention" and t["href"] == bob.remote_url
             end)

      # The Create activity mirrors the object's addressing.
      activity = NoteBuilder.create_activity(reply, alice)
      assert activity["cc"] == obj["cc"]
      assert activity["object"]["inReplyTo"] == parent.uri
    end

    test "OutboundAudience delivers a reply to the replied-to remote author" do
      alice = local!("alice")
      bob = remote!("bob")
      parent = remote_status!(bob, "http://remote.test/notes/2")

      {:ok, reply} =
        Statuses.create_local(alice, %{"status" => "hello", "in_reply_to_id" => parent.id})

      # Bob doesn't follow alice, but must still receive the reply.
      assert bob.inbox_url in OutboundAudience.inboxes_for(reply)
    end

    test "a top-level post has no inReplyTo" do
      alice = local!("alice")
      {:ok, status} = Statuses.create_local(alice, %{"status" => "standalone"})
      refute Map.has_key?(NoteBuilder.object(status), "inReplyTo")
    end
  end
end
