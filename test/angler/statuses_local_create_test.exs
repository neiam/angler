defmodule Angler.Statuses.LocalCreateTest do
  use Angler.DataCase, async: false

  alias Angler.Profiles
  alias Angler.Statuses

  defp local!(username) do
    {:ok, p} = Profiles.create_profile(%{username: username})
    p
  end

  describe "create_local/2" do
    test "happy path with text-only" do
      alice = local!("alice")

      assert {:ok, status} = Statuses.create_local(alice, %{"status" => "hello world"})
      assert status.local == true
      assert status.profile_id == alice.id
      assert status.visibility == :public
      assert status.caption == "hello world"
      assert status.rendered =~ "hello world"
      assert status.uri =~ "/p/alice/"
    end

    test "extracts and links a local mention" do
      alice = local!("alice")
      _bob = local!("bob")

      {:ok, status} =
        Statuses.create_local(alice, %{"status" => "hi @bob from @alice"})

      assert length(status.mentions) == 2
      assert status.rendered =~ "@bob"
      assert status.rendered =~ "@alice"
    end

    test "extracts hashtags and creates Hashtag rows" do
      alice = local!("alice")

      {:ok, status} =
        Statuses.create_local(alice, %{"status" => "#sunset over the lake #nature"})

      tag_names = Enum.map(status.status_hashtags, & &1.hashtag.name) |> Enum.sort()
      assert tag_names == ["nature", "sunset"]
    end

    test "rejects empty status" do
      alice = local!("alice")
      assert {:error, :empty_status} = Statuses.create_local(alice, %{"status" => ""})
      assert {:error, :empty_status} = Statuses.create_local(alice, %{})
    end

    test "rejects bad visibility" do
      alice = local!("alice")

      assert {:error, :bad_visibility} =
               Statuses.create_local(alice, %{"status" => "hi", "visibility" => "weird"})
    end

    test "accepts visibility variants" do
      alice = local!("alice")

      for v <- ["public", "unlisted", "private", "direct"] do
        {:ok, s} = Statuses.create_local(alice, %{"status" => "hi", "visibility" => v})
        assert Atom.to_string(s.visibility) == v
      end
    end

    test "stores spoiler/sensitive flags" do
      alice = local!("alice")

      {:ok, s} =
        Statuses.create_local(alice, %{
          "status" => "secret",
          "sensitive" => true,
          "spoiler_text" => "CW"
        })

      assert s.is_nsfw == true
      assert s.cw_summary == "CW"
    end

    test "reply target sets in_reply_to_id and bumps parent reply_count" do
      alice = local!("alice")
      {:ok, parent} = Statuses.create_local(alice, %{"status" => "first"})

      {:ok, reply} =
        Statuses.create_local(alice, %{
          "status" => "reply",
          "in_reply_to_id" => parent.id
        })

      assert reply.in_reply_to_id == parent.id
      assert reply.in_reply_to_profile_id == alice.id

      assert Repo.get!(Angler.Statuses.Status, parent.id).reply_count == 1
    end

    test "rejects unknown reply target" do
      alice = local!("alice")

      assert {:error, :reply_parent_not_found} =
               Statuses.create_local(alice, %{
                 "status" => "x",
                 "in_reply_to_id" => 999_999_999
               })
    end

    test "bumps author's statuses_count and last_status_at" do
      alice = local!("alice")

      before = Repo.get!(Angler.Profiles.Profile, alice.id).statuses_count
      {:ok, _} = Statuses.create_local(alice, %{"status" => "x"})
      after_ = Repo.get!(Angler.Profiles.Profile, alice.id)

      assert after_.statuses_count == before + 1
      assert after_.last_status_at
    end

    test "refuses to create on a remote profile" do
      {:ok, bob} =
        Profiles.create_profile(%{
          username: "bob",
          domain: "remote.test",
          remote_url: "http://remote.test/users/bob",
          inbox_url: "http://remote.test/users/bob/inbox",
          public_key_pem: "stub"
        })

      assert {:error, :not_local_profile} = Statuses.create_local(bob, %{"status" => "x"})
    end
  end
end
