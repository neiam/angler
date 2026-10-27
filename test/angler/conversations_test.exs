defmodule Angler.ConversationsTest do
  use Angler.DataCase, async: false

  alias Angler.Conversations
  alias Angler.Conversations.{Conversation, Participant}
  alias Angler.Profiles
  alias Angler.Statuses

  defp local!(name), do: Profiles.create_profile(%{username: name}) |> elem(1)

  describe "record/1" do
    test "files a direct status into one conversation, with a row per participant" do
      alice = local!("alice")
      bob = local!("bob")

      {:ok, status} =
        Statuses.create_local(alice, %{
          "status" => "hi @bob",
          "visibility" => "direct"
        })

      assert [conv] = Repo.all(Conversation)
      assert conv.type == "dm"
      assert conv.last_message_id == status.id

      alice_row = Repo.get_by!(Participant, conversation_id: conv.id, profile_id: alice.id)
      assert alice_row.unread_count == 0
      assert alice_row.last_read_message_id == status.id

      bob_row = Repo.get_by!(Participant, conversation_id: conv.id, profile_id: bob.id)
      assert bob_row.unread_count == 1
      # Bob doesn't follow Alice: a message request.
      assert bob_row.state == "request"
    end

    test "later messages between the same people reuse the conversation" do
      alice = local!("alice")
      bob = local!("bob")

      {:ok, _} = Statuses.create_local(alice, %{"status" => "hi @bob", "visibility" => "direct"})

      {:ok, second} =
        Statuses.create_local(alice, %{"status" => "still here @bob", "visibility" => "direct"})

      assert [conv] = Repo.all(Conversation)
      assert conv.last_message_id == second.id

      assert Repo.get_by!(Participant, conversation_id: conv.id, profile_id: bob.id).unread_count ==
               2
    end

    test "a reply accepts the request" do
      alice = local!("alice")
      bob = local!("bob")

      {:ok, _} = Statuses.create_local(alice, %{"status" => "hi @bob", "visibility" => "direct"})
      {:ok, _} = Statuses.create_local(bob, %{"status" => "@alice hey", "visibility" => "direct"})

      [conv] = Repo.all(Conversation)

      assert Repo.get_by!(Participant, conversation_id: conv.id, profile_id: bob.id).state ==
               "active"
    end

    test "no-op for non-direct visibility" do
      alice = local!("alice")
      _bob = local!("bob")

      {:ok, _} = Statuses.create_local(alice, %{"status" => "hi @bob", "visibility" => "public"})
      assert Repo.aggregate(Conversation, :count) == 0
    end
  end

  describe "mark_read / hide" do
    test "round-trip" do
      alice = local!("alice")
      bob = local!("bob")
      Statuses.create_local(alice, %{"status" => "hi @bob", "visibility" => "direct"})

      [conv] = Repo.all(Conversation)
      row = Conversations.get(bob.id, conv.id)
      assert row.unread_count == 1

      assert Conversations.mark_read(row).unread_count == 0

      Conversations.hide(row)
      cursor = Angler.Pagination.MastodonCursor.parse(%{}, 20, 40)
      assert Conversations.list_mastodon(bob.id, cursor) == []
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
