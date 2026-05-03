defmodule Angler.FollowsLocalTest do
  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Follows
  alias Angler.Follows.{FollowRequest, Follower}
  alias Angler.Profiles
  alias Angler.Profiles.Profile

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

  describe "follow/2 — local target unlocked" do
    test "creates accepted Follower + bumps both counters" do
      alice = local!("alice")
      bob = local!("bob")

      assert {:ok, :accepted, %Follower{} = follower} = Follows.follow(alice, bob)
      assert follower.profile_id == bob.id
      assert follower.following_id == alice.id
      assert follower.accepted_at

      assert Repo.get!(Profile, bob.id).followers_count == 1
      assert Repo.get!(Profile, alice.id).following_count == 1
    end

    test "is idempotent" do
      alice = local!("alice")
      bob = local!("bob")

      Follows.follow(alice, bob)
      Follows.follow(alice, bob)

      assert Repo.aggregate(Follower, :count) == 1
      # Counters not double-bumped.
      assert Repo.get!(Profile, bob.id).followers_count == 1
    end

    test "rejects self-follow" do
      alice = local!("alice")
      assert {:error, :self_follow} = Follows.follow(alice, alice)
    end
  end

  describe "follow/2 — local target locked" do
    test "creates a FollowRequest, no counter bump" do
      alice = local!("alice")
      bob = local!("bob")

      bob = bob |> Ecto.Changeset.change(is_private: true) |> Repo.update!()

      assert {:ok, :pending, %FollowRequest{}} = Follows.follow(alice, bob)
      assert Repo.aggregate(Follower, :count) == 0
      assert Repo.get!(Profile, bob.id).followers_count == 0
    end
  end

  describe "follow/2 — remote target" do
    test "creates pending_remote Follower + enqueues outbound Follow" do
      alice = local!("alice")
      bob = remote!("bob")

      assert {:ok, :pending_remote, %Follower{pending_remote: true} = follower} =
               Follows.follow(alice, bob)

      assert follower.remote_url

      assert String.starts_with?(
               follower.remote_url,
               AnglerWeb.Endpoint.url() <> "/users/alice/follows/"
             )

      assert_enqueued(
        worker: Angler.Federation.Workers.FollowDeliver,
        args: %{"verb" => "follow"}
      )

      # No counter bump until the remote Accepts.
      assert Repo.get!(Profile, bob.id).followers_count == 0
      assert Repo.get!(Profile, alice.id).following_count == 0
    end

    test "is idempotent" do
      alice = local!("alice")
      bob = remote!("bob")

      Follows.follow(alice, bob)
      Follows.follow(alice, bob)

      assert Repo.aggregate(Follower, :count) == 1
    end
  end

  describe "accept_remote!/1" do
    test "flips a pending row to accepted + bumps counters" do
      alice = local!("alice")
      bob = remote!("bob")

      {:ok, :pending_remote, follower} = Follows.follow(alice, bob)

      assert {:ok, accepted} = Follows.accept_remote!(follower.remote_url)
      assert accepted.accepted_at
      refute accepted.pending_remote

      assert Repo.get!(Profile, bob.id).followers_count == 1
      assert Repo.get!(Profile, alice.id).following_count == 1
    end

    test "is idempotent on already-accepted rows" do
      alice = local!("alice")
      bob = remote!("bob")

      {:ok, :pending_remote, follower} = Follows.follow(alice, bob)
      Follows.accept_remote!(follower.remote_url)
      Follows.accept_remote!(follower.remote_url)

      # Counters bump exactly once.
      assert Repo.get!(Profile, bob.id).followers_count == 1
    end

    test "returns :error for unknown activity_id" do
      assert {:error, :not_found} = Follows.accept_remote!("https://nope/x")
    end
  end

  describe "unfollow/2" do
    test "removes accepted edge + decrements counters + enqueues Undo for remote" do
      alice = local!("alice")
      bob = remote!("bob")

      {:ok, :pending_remote, follower} = Follows.follow(alice, bob)
      Follows.accept_remote!(follower.remote_url)

      assert Repo.get!(Profile, bob.id).followers_count == 1

      assert :ok = Follows.unfollow(alice, bob)

      assert Repo.aggregate(Follower, :count) == 0
      assert Repo.get!(Profile, bob.id).followers_count == 0
      assert Repo.get!(Profile, alice.id).following_count == 0
      assert_enqueued(worker: Angler.Federation.Workers.FollowDeliver, args: %{"verb" => "undo"})
    end

    test "is idempotent" do
      alice = local!("alice")
      bob = local!("bob")

      assert :ok = Follows.unfollow(alice, bob)
    end

    test "removing a never-accepted row does not touch counters" do
      alice = local!("alice")
      bob = remote!("bob")

      {:ok, :pending_remote, _follower} = Follows.follow(alice, bob)

      assert :ok = Follows.unfollow(alice, bob)
      assert Repo.get!(Profile, bob.id).followers_count == 0
    end
  end
end
