defmodule Angler.FollowsTest do
  use Angler.DataCase, async: false

  alias Angler.Follows
  alias Angler.Follows.{Follower, FollowRequest}
  alias Angler.Profiles

  describe "insert_inbound_follow/3" do
    setup do
      {:ok, alice} = Profiles.create_profile(%{username: "alice"})

      {:ok, bob} =
        Profiles.create_profile(%{
          username: "bob",
          domain: "remote.test",
          remote_url: "https://remote.test/users/bob"
        })

      %{alice: alice, bob: bob}
    end

    test "creates an accepted Follower row for an unlocked target", ctx do
      assert {:ok, :accepted, follower} =
               Follows.insert_inbound_follow(ctx.alice.id, ctx.bob.id,
                 remote_url: "https://remote.test/follow/1"
               )

      assert follower.profile_id == ctx.alice.id
      assert follower.following_id == ctx.bob.id
      assert follower.accepted_at
    end

    test "creates a FollowRequest for a locked target", ctx do
      Ecto.Changeset.change(ctx.alice, is_private: true) |> Repo.update!()

      assert {:ok, :pending, %FollowRequest{}} =
               Follows.insert_inbound_follow(ctx.alice.id, ctx.bob.id,
                 remote_url: "https://remote.test/follow/1"
               )
    end

    test "is idempotent — duplicate Follow returns existing row", ctx do
      {:ok, :accepted, _} =
        Follows.insert_inbound_follow(ctx.alice.id, ctx.bob.id, remote_url: "x")

      assert {:ok, :accepted, %Follower{}} =
               Follows.insert_inbound_follow(ctx.alice.id, ctx.bob.id, remote_url: "x")

      assert Repo.aggregate(Follower, :count) == 1
    end

    test "rejects self-follow", ctx do
      assert {:error, :self_follow} =
               Follows.insert_inbound_follow(ctx.alice.id, ctx.alice.id)
    end
  end

  describe "remove_inbound_follow/2" do
    setup do
      {:ok, alice} = Profiles.create_profile(%{username: "alice"})

      {:ok, bob} =
        Profiles.create_profile(%{
          username: "bob",
          domain: "remote.test",
          remote_url: "https://remote.test/users/bob"
        })

      %{alice: alice, bob: bob}
    end

    test "removes an existing follow", ctx do
      {:ok, :accepted, _} = Follows.insert_inbound_follow(ctx.alice.id, ctx.bob.id)
      assert :ok = Follows.remove_inbound_follow(ctx.alice.id, ctx.bob.id)
      assert is_nil(Follows.get_follower(ctx.alice.id, ctx.bob.id))
    end

    test "is idempotent", ctx do
      assert :ok = Follows.remove_inbound_follow(ctx.alice.id, ctx.bob.id)
    end
  end
end
