defmodule Angler.Statuses.ProfilePageTest do
  use Angler.DataCase, async: false

  alias Angler.Profiles
  alias Angler.Statuses

  defp local!(username) do
    {:ok, p} = Profiles.create_profile(%{username: username})
    p
  end

  defp post!(profile, visibility) do
    {:ok, s} =
      Statuses.create_local(profile, %{
        "status" => "post #{System.unique_integer([:positive])}",
        "visibility" => to_string(visibility)
      })

    s
  end

  describe "list_for_profile_page/2" do
    test "anonymous and other viewers see only public posts" do
      alice = local!("alice")
      pub = post!(alice, :public)
      _unlisted = post!(alice, :unlisted)
      _private = post!(alice, :private)

      assert [pub.id] ==
               alice.id |> Statuses.list_for_profile_page(viewer_id: nil) |> ids()

      bob = local!("bob")

      assert [pub.id] ==
               alice.id
               |> Statuses.list_for_profile_page(viewer_id: bob.id, filter: :all)
               |> ids()
    end

    test "owner :all sees public + unlisted + private, newest first" do
      alice = local!("alice")
      pub = post!(alice, :public)
      unlisted = post!(alice, :unlisted)
      private = post!(alice, :private)

      assert [private.id, unlisted.id, pub.id] ==
               alice.id
               |> Statuses.list_for_profile_page(viewer_id: alice.id, filter: :all)
               |> ids()
    end

    test "owner :unlisted returns only unlisted (surfaces a silent import)" do
      alice = local!("alice")
      _pub = post!(alice, :public)
      unlisted = post!(alice, :unlisted)

      assert [unlisted.id] ==
               alice.id
               |> Statuses.list_for_profile_page(viewer_id: alice.id, filter: :unlisted)
               |> ids()
    end

    test "preloads associations needed for rendering" do
      alice = local!("alice")
      _ = post!(alice, :public)

      assert [status] = Statuses.list_for_profile_page(alice.id, viewer_id: nil)
      assert %Profiles.Profile{} = status.profile
      assert is_list(status.media_attachments)
    end

    test "max_id cursor pages backwards" do
      alice = local!("alice")
      p1 = post!(alice, :public)
      p2 = post!(alice, :public)
      p3 = post!(alice, :public)

      assert [p3.id, p2.id] ==
               alice.id |> Statuses.list_for_profile_page(viewer_id: nil, limit: 2) |> ids()

      assert [p1.id] ==
               alice.id
               |> Statuses.list_for_profile_page(viewer_id: nil, limit: 2, max_id: p2.id)
               |> ids()
    end
  end

  describe "set_visibility/3" do
    test "owner lifts an unlisted post to public" do
      alice = local!("alice")
      s = post!(alice, :unlisted)

      assert {:ok, updated} = Statuses.set_visibility(s.id, alice, :public)
      assert updated.visibility == :public
      assert updated.scope == "public"
    end

    test "a non-owner is forbidden" do
      alice = local!("alice")
      bob = local!("bob")
      s = post!(alice, :unlisted)

      assert {:error, :forbidden} = Statuses.set_visibility(s.id, bob, :public)
      assert Statuses.get(s.id).visibility == :unlisted
    end

    test "missing status is not_found" do
      alice = local!("alice")
      assert {:error, :not_found} = Statuses.set_visibility(-1, alice, :public)
    end
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)
end
