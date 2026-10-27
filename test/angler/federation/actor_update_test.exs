defmodule Angler.Federation.ActorUpdateTest do
  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Federation.ActorBuilder
  alias Angler.Follows.Follower
  alias Angler.Profiles
  alias Angler.Profiles.Workers.ActorUpdateDeliver

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

  defp follows!(follower, followee) do
    %Follower{}
    |> Follower.changeset(%{
      profile_id: followee.id,
      following_id: follower.id,
      accepted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  describe "ActorBuilder" do
    test "person/1 exposes avatar + header as icon/image (absolute urls)" do
      alice = local!("alice")
      {:ok, alice} = Profiles.update_credentials(alice, %{"avatar_path" => "/storage/a.png"})

      person = ActorBuilder.person(alice)

      assert person["icon"]["type"] == "Image"
      assert String.starts_with?(person["icon"]["url"], "http")
      assert String.ends_with?(person["icon"]["url"], "/storage/a.png")
    end

    test "person/1 omits icon when no avatar is set" do
      refute Map.has_key?(ActorBuilder.person(local!("bare")), "icon")
    end

    test "update_activity wraps the actor and addresses followers" do
      alice = local!("alice")
      activity = ActorBuilder.update_activity(alice)

      assert activity["type"] == "Update"
      assert activity["object"]["type"] == "Person"
      assert activity["object"]["id"] == ActorBuilder.actor_url(alice)
      assert (ActorBuilder.actor_url(alice) <> "/followers") in activity["cc"]
    end
  end

  describe "propagation on profile change" do
    test "update_credentials enqueues an Update to each remote follower" do
      alice = local!("alice")
      bob = remote!("bob")
      follows!(bob, alice)

      {:ok, _} = Profiles.update_credentials(alice, %{"display_name" => "Alice!"})

      assert_enqueued(
        worker: ActorUpdateDeliver,
        args: %{"profile_id" => alice.id, "inbox_url" => bob.inbox_url}
      )
    end

    test "no Update job when the author has no remote followers" do
      alice = local!("alice")
      {:ok, _} = Profiles.update_credentials(alice, %{"display_name" => "Solo"})
      refute_enqueued(worker: ActorUpdateDeliver)
    end
  end

  describe "account deletion" do
    test "sends Delete Person to each remote follower" do
      {:ok, %{user: user, profile: alice}} =
        Angler.Accounts.register(%{
          username: "alice",
          email: "a@example.com",
          password: "verysecret123"
        })

      bob = remote!("bob")
      follows!(bob, alice)

      {:ok, _} = Angler.Accounts.delete_own_account(user, "verysecret123")

      assert_enqueued(
        worker: ActorUpdateDeliver,
        args: %{"profile_id" => alice.id, "inbox_url" => bob.inbox_url, "kind" => "delete"}
      )

      activity = ActorBuilder.delete_activity(alice)
      assert activity["type"] == "Delete"
      assert activity["object"] == %{"id" => ActorBuilder.actor_url(alice), "type" => "Person"}
      refute "https://www.w3.org/ns/activitystreams#Public" in activity["to"]
    end
  end
end
