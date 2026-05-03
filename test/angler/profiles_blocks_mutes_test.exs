defmodule Angler.Profiles.BlocksMutesTest do
  use Angler.DataCase, async: false

  alias Angler.Follows
  alias Angler.Profiles
  alias Angler.Profiles.{Block, BlocksMutes, Mute}

  defp local!(username), do: Profiles.create_profile(%{username: username}) |> elem(1)

  describe "block/2" do
    test "inserts a block row, idempotent" do
      a = local!("a")
      b = local!("b")

      {:ok, %Block{}} = BlocksMutes.block(a, b)
      {:ok, %Block{}} = BlocksMutes.block(a, b)

      assert Repo.aggregate(Block, :count) == 1
      assert BlocksMutes.blocked?(a.id, b.id)
    end

    test "tears down follow edges in both directions" do
      a = local!("a")
      b = local!("b")

      Follows.follow(a, b)
      Follows.follow(b, a)
      assert Follows.get_follower(b.id, a.id)
      assert Follows.get_follower(a.id, b.id)

      {:ok, _} = BlocksMutes.block(a, b)

      refute Follows.get_follower(b.id, a.id)
      refute Follows.get_follower(a.id, b.id)
    end

    test "rejects self-block" do
      a = local!("a")
      assert {:error, :self_block} = BlocksMutes.block(a, a)
    end
  end

  describe "unblock/2" do
    test "removes the block" do
      a = local!("a")
      b = local!("b")

      {:ok, _} = BlocksMutes.block(a, b)
      :ok = BlocksMutes.unblock(a, b)

      refute BlocksMutes.blocked?(a.id, b.id)
    end
  end

  describe "block_ids_for/1" do
    test "returns ids the actor blocks AND ids that block the actor" do
      a = local!("a")
      b = local!("b")
      c = local!("c")

      {:ok, _} = BlocksMutes.block(a, b)
      {:ok, _} = BlocksMutes.block(c, a)

      assert MapSet.new(BlocksMutes.block_ids_for(a.id)) == MapSet.new([b.id, c.id])
    end
  end

  describe "mute/3" do
    test "inserts mute with hide_notifications=true by default" do
      a = local!("a")
      b = local!("b")

      assert {:ok, %Mute{hide_notifications: true}} = BlocksMutes.mute(a, b)
    end

    test "is upsert: re-mute updates hide_notifications" do
      a = local!("a")
      b = local!("b")

      {:ok, _} = BlocksMutes.mute(a, b, notifications: true)
      {:ok, _} = BlocksMutes.mute(a, b, notifications: false)

      [m] = Repo.all(Mute)
      assert m.hide_notifications == false
    end

    test "rejects self-mute" do
      a = local!("a")
      assert {:error, :self_mute} = BlocksMutes.mute(a, a)
    end
  end

  describe "list_blocks / list_mutes" do
    test "returns the targets newest-first" do
      a = local!("a")
      b1 = local!("b1")
      b2 = local!("b2")

      {:ok, _} = BlocksMutes.block(a, b1)
      {:ok, _} = BlocksMutes.block(a, b2)

      [first, second] = BlocksMutes.list_blocks(a.id)
      assert first.id == b2.id
      assert second.id == b1.id
    end
  end
end
