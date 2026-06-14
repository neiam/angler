defmodule Angler.Federation.NoteBuilderTest do
  use Angler.DataCase, async: false

  alias Angler.Federation.NoteBuilder
  alias Angler.Media.Asset
  alias Angler.Profiles
  alias Angler.Statuses

  defp local!(username) do
    {:ok, p} = Profiles.create_profile(%{username: username})
    p
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
end
