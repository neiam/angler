defmodule Angler.FollowRequestsTest do
  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Follows
  alias Angler.Follows.{FollowRequest, Follower}
  alias Angler.Notifications.Notification
  alias Angler.Profiles

  defp local!(username, opts \\ []) do
    {:ok, p} = Profiles.create_profile(Map.merge(%{username: username}, Map.new(opts)))
    p
  end

  defp remote!(username, domain) do
    {:ok, p} =
      Profiles.create_profile(%{
        username: username,
        domain: domain,
        remote_url: "http://#{domain}/users/#{username}",
        inbox_url: "http://#{domain}/users/#{username}/inbox",
        public_key_pem: "stub"
      })

    p
  end

  describe "list_requests/2" do
    test "returns pending requests for the target, newest first" do
      target = local!("locked", is_private: true)
      a = local!("a")
      b = local!("b")

      Follows.follow(a, target)
      Follows.follow(b, target)

      [first, second] = Follows.list_requests(target.id)
      assert first.follower.id == b.id
      assert second.follower.id == a.id
    end
  end

  describe "authorize_request/2" do
    test "promotes pending request to accepted Follower + bumps counters + creates notification" do
      target = local!("locked", is_private: true)
      follower = local!("alice")

      {:ok, :pending, _fr} = Follows.follow(follower, target)
      assert Repo.aggregate(FollowRequest, :count) == 1

      {:ok, %Follower{} = row} = Follows.authorize_request(target, follower)

      assert row.accepted_at
      assert Repo.aggregate(FollowRequest, :count) == 0

      target_reloaded = Repo.get!(Profiles.Profile, target.id)
      follower_reloaded = Repo.get!(Profiles.Profile, follower.id)

      assert target_reloaded.followers_count == 1
      assert follower_reloaded.following_count == 1

      # `insert_request` already created a "follow_request" notification at
      # follow time; authorizing layers a "follow" notification on top.
      types = Repo.all(Notification) |> Enum.map(& &1.type) |> Enum.sort()
      assert types == ["follow", "follow_request"]
    end

    test "remote follower → outbound Accept enqueued" do
      target = local!("locked", is_private: true)
      remote = remote!("bob", "remote.test")

      {:ok, :pending, _fr} =
        Follows.insert_inbound_follow(target.id, remote.id,
          remote_url: "http://remote.test/follows/abc"
        )

      {:ok, _} = Follows.authorize_request(target, remote)

      assert_enqueued(
        worker: Angler.Federation.Workers.FollowDeliver,
        args: %{"verb" => "accept", "follow_activity_id" => "http://remote.test/follows/abc"}
      )
    end

    test "no pending request → :not_found" do
      target = local!("a")
      ghost = local!("b")
      assert {:error, :not_found} = Follows.authorize_request(target, ghost)
    end
  end

  describe "reject_request/2" do
    test "deletes the request, no follower row inserted" do
      target = local!("locked", is_private: true)
      follower = local!("a")

      Follows.follow(follower, target)
      assert :ok = Follows.reject_request(target, follower)

      assert Repo.aggregate(FollowRequest, :count) == 0
      refute Follows.get_follower(target.id, follower.id)
    end

    test "remote follower → outbound Reject enqueued" do
      target = local!("locked", is_private: true)
      remote = remote!("bob", "remote.test")

      {:ok, :pending, _fr} =
        Follows.insert_inbound_follow(target.id, remote.id,
          remote_url: "http://remote.test/follows/xyz"
        )

      assert :ok = Follows.reject_request(target, remote)

      assert_enqueued(
        worker: Angler.Federation.Workers.FollowDeliver,
        args: %{"verb" => "reject", "follow_activity_id" => "http://remote.test/follows/xyz"}
      )
    end

    test "no request → :ok (idempotent)" do
      target = local!("a")
      ghost = local!("b")
      assert :ok = Follows.reject_request(target, ghost)
    end
  end
end
