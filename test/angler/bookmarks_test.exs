defmodule Angler.BookmarksTest do
  use Angler.DataCase, async: false

  alias Angler.Bookmarks
  alias Angler.Bookmarks.Bookmark
  alias Angler.Profiles
  alias Angler.Statuses

  defp local!(username) do
    {:ok, p} = Profiles.create_profile(%{username: username})
    p
  end

  defp insert_status!(profile) do
    {:ok, s} =
      Statuses.create_remote(%{
        profile_id: profile.id,
        visibility: :public,
        caption: "x",
        rendered: "<p>x</p>",
        type: "text",
        local: true,
        uri: nil
      })

    s
  end

  test "bookmark/2 inserts a row" do
    alice = local!("alice")
    bob = local!("bob")
    s = insert_status!(bob)

    assert {:ok, %Bookmark{}} = Bookmarks.bookmark(alice.id, s.id)
    assert Bookmarks.bookmarked?(alice.id, s.id)
  end

  test "bookmark/2 is idempotent" do
    alice = local!("alice")
    bob = local!("bob")
    s = insert_status!(bob)

    Bookmarks.bookmark(alice.id, s.id)
    Bookmarks.bookmark(alice.id, s.id)

    assert Repo.aggregate(Bookmark, :count) == 1
  end

  test "unbookmark/2 removes the row" do
    alice = local!("alice")
    bob = local!("bob")
    s = insert_status!(bob)

    Bookmarks.bookmark(alice.id, s.id)
    assert :ok = Bookmarks.unbookmark(alice.id, s.id)
    refute Bookmarks.bookmarked?(alice.id, s.id)
  end

  test "unbookmark/2 is idempotent" do
    alice = local!("alice")
    assert :ok = Bookmarks.unbookmark(alice.id, 999_999_999)
  end
end
