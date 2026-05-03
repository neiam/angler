defmodule Angler.Statuses.ViewerOverlayTest do
  use Angler.DataCase, async: false

  alias Angler.Bookmarks
  alias Angler.Profiles
  alias Angler.Statuses
  alias Angler.Statuses.ViewerOverlay

  defp local!(u) do
    {:ok, p} = Profiles.create_profile(%{username: u})
    p
  end

  defp local_status!(profile) do
    {:ok, s} =
      Statuses.create_remote(%{
        profile_id: profile.id,
        visibility: :public,
        caption: "x",
        rendered: "<p>x</p>",
        type: "text",
        local: true
      })

    s
  end

  test "empty/2 — all false" do
    o = ViewerOverlay.empty()
    refute o.favourited
    refute o.reblogged
    refute o.bookmarked
    refute o.pinned
    refute o.muted
  end

  test "batch/2 — nil viewer returns empty map" do
    assert ViewerOverlay.batch(nil, [1, 2, 3]) == %{}
  end

  test "batch/2 — empty status list returns empty map" do
    alice = local!("alice")
    assert ViewerOverlay.batch(alice.id, []) == %{}
  end

  test "batch/2 — populates favourited/reblogged/bookmarked correctly" do
    alice = local!("alice")
    bob = local!("bob")
    s1 = local_status!(bob)
    s2 = local_status!(bob)
    s3 = local_status!(bob)

    {:ok, _} = Statuses.favourite(alice, s1)
    {:ok, _} = Statuses.reblog(alice, s2)
    {:ok, _} = Bookmarks.bookmark(alice.id, s3.id)

    overlays = ViewerOverlay.batch(alice.id, [s1.id, s2.id, s3.id])

    assert overlays[s1.id].favourited == true
    refute overlays[s1.id].reblogged
    refute overlays[s1.id].bookmarked

    assert overlays[s2.id].reblogged == true
    refute overlays[s2.id].favourited

    assert overlays[s3.id].bookmarked == true
    refute overlays[s3.id].favourited
    refute overlays[s3.id].reblogged
  end

  test "for_status/2 — single-status convenience" do
    alice = local!("alice")
    bob = local!("bob")
    s = local_status!(bob)

    {:ok, _} = Statuses.favourite(alice, s)

    assert %{favourited: true, reblogged: false, bookmarked: false} =
             ViewerOverlay.for_status(alice.id, s.id)
  end
end
