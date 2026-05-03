defmodule Angler.ProfilesTest do
  use Angler.DataCase, async: false

  alias Angler.Profiles
  alias Angler.Profiles.Profile

  describe "get_local_by_username/1" do
    test "returns a local profile by exact username" do
      {:ok, profile} = Profiles.create_profile(%{username: "alice"})

      assert %Profile{id: id, username: "alice", domain: nil} =
               Profiles.get_local_by_username("alice")

      assert id == profile.id
    end

    test "is case-insensitive (citext)" do
      {:ok, _} = Profiles.create_profile(%{username: "Alice"})

      assert Profiles.get_local_by_username("alice")
      assert Profiles.get_local_by_username("ALICE")
    end

    test "ignores remote profiles with the same username" do
      {:ok, _local} = Profiles.create_profile(%{username: "alice"})
      {:ok, _remote} = Profiles.create_profile(%{username: "alice", domain: "remote.test"})

      assert %Profile{domain: nil} = Profiles.get_local_by_username("alice")
    end

    test "ignores soft-deleted profiles" do
      {:ok, _} = Profiles.create_profile(%{username: "alice", status: "deleted"})

      assert is_nil(Profiles.get_local_by_username("alice"))
    end

    test "returns nil for missing username" do
      assert is_nil(Profiles.get_local_by_username("nope"))
    end
  end

  describe "url/1 and actor_url/1" do
    test "local profile uses /@username and /users/username" do
      {:ok, profile} = Profiles.create_profile(%{username: "alice"})

      assert String.ends_with?(Profiles.url(profile), "/@alice")
      assert String.ends_with?(Profiles.actor_url(profile), "/users/alice")
    end

    test "remote profile uses remote_url" do
      {:ok, profile} =
        Profiles.create_profile(%{
          username: "bob",
          domain: "remote.test",
          remote_url: "https://remote.test/users/bob"
        })

      assert Profiles.url(profile) == "https://remote.test/users/bob"
      assert Profiles.actor_url(profile) == "https://remote.test/users/bob"
    end
  end
end
