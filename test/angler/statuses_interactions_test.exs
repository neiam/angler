defmodule Angler.StatusesInteractionsTest do
  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Likes.Like
  alias Angler.Profiles
  alias Angler.Reblogs.Reblog
  alias Angler.Statuses
  alias Angler.Statuses.Status

  defp local!(u) do
    {:ok, p} = Profiles.create_profile(%{username: u})
    p
  end

  defp remote!(u) do
    {:ok, p} =
      Profiles.create_profile(%{
        username: u,
        domain: "remote.test",
        remote_url: "http://remote.test/users/#{u}",
        inbox_url: "http://remote.test/users/#{u}/inbox",
        public_key_pem: "stub"
      })

    p
  end

  defp local_status!(profile, attrs \\ %{}) do
    {:ok, s} =
      Statuses.create_remote(
        Map.merge(
          %{
            profile_id: profile.id,
            visibility: :public,
            caption: "x",
            rendered: "<p>x</p>",
            type: "text",
            local: true,
            uri: nil
          },
          attrs
        )
      )

    s
  end

  defp remote_status!(profile) do
    uri = "http://remote.test/notes/#{System.unique_integer([:positive])}"

    {:ok, s} =
      Statuses.create_remote(%{
        profile_id: profile.id,
        visibility: :public,
        caption: "x",
        rendered: "<p>x</p>",
        type: "text",
        local: false,
        uri: uri,
        url: uri
      })

    s
  end

  ## Favourite

  describe "favourite/2" do
    test "local-author status: row + counter, no outbound" do
      alice = local!("alice")
      bob = local!("bob")
      s = local_status!(bob)

      assert {:ok, fresh} = Statuses.favourite(alice, s)
      assert fresh.likes_count == 1
      assert Repo.aggregate(Like, :count) == 1

      refute_enqueued(worker: Angler.Statuses.Workers.InteractionDeliver)
    end

    test "remote-author status: row + counter + outbound Like enqueued" do
      alice = local!("alice")
      bob = remote!("bob")
      s = remote_status!(bob)

      assert {:ok, fresh} = Statuses.favourite(alice, s)
      assert fresh.likes_count == 1

      assert_enqueued(
        worker: Angler.Statuses.Workers.InteractionDeliver,
        args: %{"verb" => "like"}
      )
    end

    test "is idempotent — counter doesn't double-bump" do
      alice = local!("alice")
      bob = local!("bob")
      s = local_status!(bob)

      Statuses.favourite(alice, s)
      Statuses.favourite(alice, s)

      assert Repo.get!(Status, s.id).likes_count == 1
    end
  end

  describe "unfavourite/2" do
    test "removes row + decrements counter" do
      alice = local!("alice")
      bob = local!("bob")
      s = local_status!(bob)

      {:ok, _} = Statuses.favourite(alice, s)
      assert {:ok, fresh} = Statuses.unfavourite(alice, s)
      assert fresh.likes_count == 0
      assert Repo.aggregate(Like, :count) == 0
    end

    test "is idempotent (no row → returns ok)" do
      alice = local!("alice")
      bob = local!("bob")
      s = local_status!(bob)

      assert {:ok, _} = Statuses.unfavourite(alice, s)
    end

    test "remote-author: enqueues Undo Like" do
      alice = local!("alice")
      bob = remote!("bob")
      s = remote_status!(bob)

      Statuses.favourite(alice, s)
      Statuses.unfavourite(alice, s)

      assert_enqueued(
        worker: Angler.Statuses.Workers.InteractionDeliver,
        args: %{"verb" => "undo_like"}
      )
    end
  end

  ## Reblog

  describe "reblog/2" do
    test "happy path: row + counter, remote → outbound Announce" do
      alice = local!("alice")
      bob = remote!("bob")
      s = remote_status!(bob)

      assert {:ok, fresh} = Statuses.reblog(alice, s)
      assert fresh.reblogs_count == 1
      assert Repo.aggregate(Reblog, :count) == 1

      assert_enqueued(
        worker: Angler.Statuses.Workers.InteractionDeliver,
        args: %{"verb" => "announce"}
      )
    end

    test "private/direct statuses cannot be reblogged" do
      alice = local!("alice")
      bob = local!("bob")
      private = local_status!(bob, %{visibility: :private})
      direct = local_status!(bob, %{visibility: :direct})

      assert {:error, :unrebloggable} = Statuses.reblog(alice, private)
      assert {:error, :unrebloggable} = Statuses.reblog(alice, direct)
    end

    test "idempotent" do
      alice = local!("alice")
      bob = local!("bob")
      s = local_status!(bob)

      Statuses.reblog(alice, s)
      Statuses.reblog(alice, s)

      assert Repo.get!(Status, s.id).reblogs_count == 1
    end
  end

  describe "unreblog/2" do
    test "removes + decrements" do
      alice = local!("alice")
      bob = local!("bob")
      s = local_status!(bob)

      {:ok, _} = Statuses.reblog(alice, s)
      {:ok, fresh} = Statuses.unreblog(alice, s)

      assert fresh.reblogs_count == 0
    end

    test "remote → enqueues Undo Announce" do
      alice = local!("alice")
      bob = remote!("bob")
      s = remote_status!(bob)

      {:ok, _} = Statuses.reblog(alice, s)
      {:ok, _} = Statuses.unreblog(alice, s)

      assert_enqueued(
        worker: Angler.Statuses.Workers.InteractionDeliver,
        args: %{"verb" => "undo_announce"}
      )
    end
  end

  ## Liker / booster lists

  describe "list_likers/2" do
    test "returns the profiles who favourited, newest first" do
      alice = local!("alice")
      bob = local!("bob")
      carol = local!("carol")
      s = local_status!(carol)

      Statuses.favourite(alice, s)
      Statuses.favourite(bob, s)

      ids = s.id |> Statuses.list_likers() |> Enum.map(& &1.id)
      assert ids == [bob.id, alice.id]
    end

    test "empty when nobody liked" do
      s = local_status!(local!("carol"))
      assert Statuses.list_likers(s.id) == []
    end

    test "respects the limit option" do
      bob = local!("bob")
      s = local_status!(bob)
      Statuses.favourite(local!("alice"), s)
      Statuses.favourite(local!("carol"), s)

      assert length(Statuses.list_likers(s.id, limit: 1)) == 1
    end
  end

  describe "list_boosters/2" do
    test "returns the profiles who reblogged, newest first" do
      alice = local!("alice")
      bob = local!("bob")
      carol = local!("carol")
      s = local_status!(carol)

      Statuses.reblog(alice, s)
      Statuses.reblog(bob, s)

      ids = s.id |> Statuses.list_boosters() |> Enum.map(& &1.id)
      assert ids == [bob.id, alice.id]
    end

    test "empty when nobody boosted" do
      s = local_status!(local!("carol"))
      assert Statuses.list_boosters(s.id) == []
    end
  end
end
