defmodule Angler.ConversationsTest do
  use Angler.DataCase, async: false

  alias Angler.Conversations
  alias Angler.Conversations.Conversation
  alias Angler.Profiles
  alias Angler.Statuses

  defp local!(name), do: Profiles.create_profile(%{username: name}) |> elem(1)

  describe "record/1" do
    test "creates a conversation row per participant for a direct status" do
      alice = local!("alice")
      bob = local!("bob")

      {:ok, status} =
        Statuses.create_local(alice, %{
          "status" => "hi @bob",
          "visibility" => "direct"
        })

      conversations = Repo.all(Conversation)
      assert length(conversations) == 2

      [alice_conv] = Enum.filter(conversations, &(&1.owner_id == alice.id))
      assert alice_conv.participant_ids == [bob.id]
      assert alice_conv.last_status_id == status.id
      refute alice_conv.unread

      [bob_conv] = Enum.filter(conversations, &(&1.owner_id == bob.id))
      assert bob_conv.participant_ids == [alice.id]
      assert bob_conv.unread
    end

    test "subsequent direct messages between same set bump existing rows" do
      alice = local!("alice")
      _bob = local!("bob")

      {:ok, _} = Statuses.create_local(alice, %{"status" => "hi @bob", "visibility" => "direct"})

      {:ok, second} =
        Statuses.create_local(alice, %{"status" => "still here @bob", "visibility" => "direct"})

      assert Repo.aggregate(Conversation, :count) == 2
      conv = Repo.get_by!(Conversation, owner_id: alice.id)
      assert conv.last_status_id == second.id
    end

    test "no-op for non-direct visibility" do
      alice = local!("alice")
      _bob = local!("bob")

      {:ok, _} = Statuses.create_local(alice, %{"status" => "hi @bob", "visibility" => "public"})
      assert Repo.aggregate(Conversation, :count) == 0
    end
  end

  describe "list / mark_read / delete" do
    test "round-trip" do
      alice = local!("alice")
      bob = local!("bob")
      Statuses.create_local(alice, %{"status" => "hi @bob", "visibility" => "direct"})

      [conv] = Conversations.list(bob.id)
      assert conv.unread

      {:ok, read} = Conversations.mark_read(bob.id, conv.id)
      refute read.unread

      :ok = Conversations.delete(bob.id, conv.id)
      assert Conversations.list(bob.id) == []
    end
  end

  describe "direct_timeline/2" do
    test "returns the last status of each thread" do
      alice = local!("alice")
      bob = local!("bob")

      {:ok, _} =
        Statuses.create_local(alice, %{"status" => "first @bob", "visibility" => "direct"})

      {:ok, second} =
        Statuses.create_local(alice, %{"status" => "second @bob", "visibility" => "direct"})

      [s] = Conversations.direct_timeline(alice.id)
      assert s.id == second.id
    end
  end
end
