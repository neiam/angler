defmodule Angler.RelationshipsTest do
  use Angler.DataCase, async: false

  alias Angler.Follows
  alias Angler.Profiles
  alias Angler.Relationships

  defp local!(username) do
    {:ok, p} = Profiles.create_profile(%{username: username})
    p
  end

  test "all-false defaults for unrelated targets" do
    alice = local!("alice")
    bob = local!("bob")

    rel = Relationships.get(alice.id, bob.id)
    assert rel.id == bob.id
    refute rel.following
    refute rel.followed_by
    refute rel.requested
    refute rel.requested_by
    assert rel.showing_reblogs == true
    refute rel.notifying
    refute rel.blocking
    refute rel.blocked_by
    refute rel.muting
  end

  test "following = true after alice follows bob" do
    alice = local!("alice")
    bob = local!("bob")

    {:ok, :accepted, _} = Follows.follow(alice, bob)

    assert Relationships.get(alice.id, bob.id).following == true
    assert Relationships.get(bob.id, alice.id).followed_by == true
  end

  test "mutual follow flips both following and followed_by" do
    alice = local!("alice")
    bob = local!("bob")

    Follows.follow(alice, bob)
    Follows.follow(bob, alice)

    a_to_b = Relationships.get(alice.id, bob.id)
    assert a_to_b.following
    assert a_to_b.followed_by
  end

  test "locked target → requested = true, following = false" do
    alice = local!("alice")
    bob = local!("bob") |> Ecto.Changeset.change(is_private: true) |> Repo.update!()

    {:ok, :pending, _} = Follows.follow(alice, bob)

    rel = Relationships.get(alice.id, bob.id)
    refute rel.following
    assert rel.requested == true
    assert Relationships.get(bob.id, alice.id).requested_by == true
  end

  test "batch returns one entry per target with stable shape" do
    alice = local!("alice")
    bob = local!("bob")
    carol = local!("carol")

    Follows.follow(alice, bob)

    rels = Relationships.batch(alice.id, [bob.id, carol.id])
    assert Map.has_key?(rels, bob.id)
    assert Map.has_key?(rels, carol.id)
    assert rels[bob.id].following
    refute rels[carol.id].following
  end

  test "empty target list returns empty map" do
    alice = local!("alice")
    assert Relationships.batch(alice.id, []) == %{}
  end
end
