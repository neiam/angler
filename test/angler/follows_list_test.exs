defmodule Angler.FollowsListTest do
  use Angler.DataCase, async: false

  alias Angler.Follows
  alias Angler.Profiles

  defp local!(username) do
    {:ok, p} = Profiles.create_profile(%{username: username})
    p
  end

  describe "list_followers/2" do
    test "returns accounts that follow the profile" do
      alice = local!("alice")
      bob = local!("bob")
      carol = local!("carol")

      {:ok, :accepted, _} = Follows.follow(bob, alice)
      {:ok, :accepted, _} = Follows.follow(carol, alice)

      ids = alice |> Follows.list_followers() |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([bob.id, carol.id])
    end

    test "does not include accounts the profile follows" do
      alice = local!("alice")
      bob = local!("bob")

      {:ok, :accepted, _} = Follows.follow(alice, bob)

      assert Follows.list_followers(alice) == []
    end

    test "respects :limit" do
      alice = local!("alice")
      {:ok, :accepted, _} = Follows.follow(local!("bob"), alice)
      {:ok, :accepted, _} = Follows.follow(local!("carol"), alice)

      assert length(Follows.list_followers(alice, limit: 1)) == 1
    end
  end

  describe "list_following/2" do
    test "returns accounts the profile follows" do
      alice = local!("alice")
      bob = local!("bob")
      carol = local!("carol")

      {:ok, :accepted, _} = Follows.follow(alice, bob)
      {:ok, :accepted, _} = Follows.follow(alice, carol)

      ids = alice |> Follows.list_following() |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([bob.id, carol.id])
    end

    test "excludes pending follow requests to private accounts" do
      alice = local!("alice")
      {:ok, locked} = Profiles.create_profile(%{username: "locked", is_private: true})

      {:ok, :pending, _} = Follows.follow(alice, locked)

      assert Follows.list_following(alice) == []
    end
  end
end
