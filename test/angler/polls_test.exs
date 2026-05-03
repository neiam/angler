defmodule Angler.PollsTest do
  use Angler.DataCase, async: false

  alias Angler.Polls
  alias Angler.Polls.{Option, Poll, Vote}
  alias Angler.Profiles
  alias Angler.Statuses

  defp local!(name), do: Profiles.create_profile(%{username: name}) |> elem(1)

  defp insert_status!(profile, opts \\ []) do
    {:ok, s} =
      Statuses.create_remote(%{
        profile_id: profile.id,
        visibility: opts[:visibility] || :public,
        caption: "x",
        rendered: "<p>x</p>",
        type: "text",
        local: true,
        uri: nil
      })

    s
  end

  describe "create/2" do
    test "happy path: stores poll + ordered options" do
      author = local!("alice")
      status = insert_status!(author)

      {:ok, poll} =
        Polls.create(status, %{
          "options" => ["a", "b", "c"],
          "expires_in" => 3600,
          "multiple" => false
        })

      assert poll.status_id == status.id
      assert length(poll.options) == 3
      assert Enum.map(poll.options, & &1.title) == ["a", "b", "c"]
      assert Enum.map(poll.options, & &1.position) == [0, 1, 2]
    end

    test "rejects too few / too many options" do
      author = local!("alice")
      status = insert_status!(author)

      assert {:error, :too_few_options} =
               Polls.create(status, %{"options" => ["only"], "expires_in" => 3600})

      too_many = Enum.map(1..(Polls.max_options() + 1), &"o#{&1}")

      assert {:error, :too_many_options} =
               Polls.create(status, %{"options" => too_many, "expires_in" => 3600})
    end

    test "rejects bad expires_in" do
      author = local!("alice")
      status = insert_status!(author)

      assert {:error, :bad_expires_in} = Polls.create(status, %{"options" => ["a", "b"]})

      assert {:error, :expires_too_soon} =
               Polls.create(status, %{"options" => ["a", "b"], "expires_in" => 30})
    end
  end

  describe "vote/3" do
    setup do
      author = local!("alice")
      status = insert_status!(author)
      voter = local!("voter")

      {:ok, poll} =
        Polls.create(status, %{
          "options" => ["red", "blue", "green"],
          "expires_in" => 3600
        })

      %{poll: poll, voter: voter, author: author}
    end

    test "single-choice records the vote and bumps counters", ctx do
      {:ok, updated} = Polls.vote(ctx.poll, ctx.voter, [1])

      [opt] = Enum.filter(updated.options, &(&1.position == 1))
      assert opt.votes_count == 1
      assert updated.voters_count == 1
      assert Polls.voted_option_ids(ctx.poll.id, ctx.voter.id) == [opt.id]
    end

    test "rejects multiple choices on a single-choice poll", ctx do
      assert {:error, :too_many_choices} = Polls.vote(ctx.poll, ctx.voter, [0, 1])
    end

    test "is idempotent on the same option", ctx do
      Polls.vote(ctx.poll, ctx.voter, [1])
      Polls.vote(ctx.poll, ctx.voter, [1])

      assert Repo.aggregate(Vote, :count) == 1

      [opt] = Repo.all(from o in Option, where: o.poll_id == ^ctx.poll.id and o.position == 1)
      assert opt.votes_count == 1

      [reloaded_poll] = Repo.all(Poll)
      assert reloaded_poll.voters_count == 1
    end

    test "rejects votes after expiry", ctx do
      ctx.poll
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -10, :second))
      |> Repo.update!()

      stale = Polls.get(ctx.poll.id)
      assert {:error, :poll_expired} = Polls.vote(stale, ctx.voter, [0])
    end

    test "rejects unknown option index", ctx do
      assert {:error, :unknown_option} = Polls.vote(ctx.poll, ctx.voter, [42])
    end
  end

  describe "multi-choice polls" do
    test "vote/3 accepts multiple, bumps counters once each" do
      author = local!("a")
      status = insert_status!(author)
      voter = local!("v")

      {:ok, poll} =
        Polls.create(status, %{
          "options" => ["x", "y", "z"],
          "expires_in" => 3600,
          "multiple" => true
        })

      {:ok, updated} = Polls.vote(poll, voter, [0, 2])

      [a, _b, c] = Enum.sort_by(updated.options, & &1.position)
      assert a.votes_count == 1
      assert c.votes_count == 1
      assert updated.voters_count == 1
    end
  end

  import Ecto.Query, only: [from: 2]
end
