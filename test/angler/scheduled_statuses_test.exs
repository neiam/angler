defmodule Angler.ScheduledStatusesTest do
  use Angler.DataCase, async: false

  alias Angler.Profiles
  alias Angler.Statuses.{Scheduled, Scheduling}

  defp local!(username), do: Profiles.create_profile(%{username: username}) |> elem(1)

  defp future_iso(seconds_from_now) do
    DateTime.utc_now() |> DateTime.add(seconds_from_now, :second) |> DateTime.to_iso8601()
  end

  describe "scheduled?/1" do
    test "true when scheduled_at is more than 5 minutes ahead" do
      assert Scheduling.scheduled?(%{"scheduled_at" => future_iso(600)})
    end

    test "false when within the 5-minute window" do
      refute Scheduling.scheduled?(%{"scheduled_at" => future_iso(60)})
    end

    test "false when missing or unparseable" do
      refute Scheduling.scheduled?(%{})
      refute Scheduling.scheduled?(%{"scheduled_at" => "tomorrow"})
    end
  end

  describe "schedule/2" do
    test "stores params and media_ids" do
      profile = local!("alice")

      {:ok, %Scheduled{} = row} =
        Scheduling.schedule(profile, %{
          "status" => "in the future",
          "visibility" => "public",
          "scheduled_at" => future_iso(900),
          "media_ids" => ["1", "2"]
        })

      assert row.profile_id == profile.id
      assert row.media_ids == [1, 2]
      assert row.params["status"] == "in the future"
      refute Map.has_key?(row.params, "scheduled_at")
      refute Map.has_key?(row.params, "media_ids")
    end

    test "rejects bad timestamp" do
      profile = local!("alice")
      assert {:error, :bad_scheduled_at} = Scheduling.schedule(profile, %{"scheduled_at" => "x"})
    end
  end

  describe "fire_due/0" do
    test "creates a status for due rows and marks them fired" do
      profile = local!("alice")

      {:ok, due} =
        Scheduling.schedule(profile, %{
          "status" => "due now",
          "visibility" => "public",
          "scheduled_at" => future_iso(900)
        })

      # Force scheduled_at into the past.
      due
      |> Ecto.Changeset.change(scheduled_at: DateTime.add(DateTime.utc_now(), -10, :second))
      |> Repo.update!()

      assert {1, 0} = Scheduling.fire_due()

      reloaded = Repo.get!(Scheduled, due.id)
      assert reloaded.fired_at

      # A real Status row exists with that caption.
      assert Repo.exists?(
               from s in Angler.Statuses.Status,
                 where: s.caption == "due now" and s.profile_id == ^profile.id
             )
    end

    test "is idempotent: a second pass fires nothing" do
      profile = local!("alice")

      {:ok, row} =
        Scheduling.schedule(profile, %{
          "status" => "x",
          "visibility" => "public",
          "scheduled_at" => future_iso(900)
        })

      row
      |> Ecto.Changeset.change(scheduled_at: DateTime.add(DateTime.utc_now(), -10, :second))
      |> Repo.update!()

      assert {1, 0} = Scheduling.fire_due()
      assert {0, 0} = Scheduling.fire_due()
    end
  end

  describe "list / get / update / delete" do
    test "round-trip", _ctx do
      a = local!("a")
      b = local!("b")

      {:ok, row} =
        Scheduling.schedule(a, %{
          "status" => "x",
          "visibility" => "public",
          "scheduled_at" => future_iso(900)
        })

      assert [^row] = Scheduling.list(a.id) |> Enum.map(& &1)
      assert Scheduling.get(a.id, row.id)
      refute Scheduling.get(b.id, row.id)

      new_at = DateTime.utc_now() |> DateTime.add(1800, :second)
      {:ok, updated} = Scheduling.update_scheduled_at(row, new_at)
      assert DateTime.to_unix(updated.scheduled_at) == DateTime.to_unix(new_at)

      :ok = Scheduling.delete(a.id, row.id)
      refute Scheduling.get(a.id, row.id)
    end

    test "update rejects too-soon timestamps" do
      a = local!("a")

      {:ok, row} =
        Scheduling.schedule(a, %{
          "status" => "x",
          "visibility" => "public",
          "scheduled_at" => future_iso(900)
        })

      assert {:error, :too_soon} =
               Scheduling.update_scheduled_at(row, DateTime.add(DateTime.utc_now(), 60, :second))
    end
  end

  import Ecto.Query
end
