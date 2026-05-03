defmodule Angler.NotificationsTest do
  use Angler.DataCase, async: false

  alias Angler.Follows
  alias Angler.Notifications
  alias Angler.Notifications.Notification
  alias Angler.Profiles
  alias Angler.Statuses

  defp local!(username) do
    {:ok, p} = Profiles.create_profile(%{username: username})
    p
  end

  defp insert_status!(profile) do
    {:ok, s} =
      Statuses.create_remote(%{
        profile_id: profile.id,
        visibility: :public,
        caption: "x",
        rendered: "<p>x</p>",
        type: "text",
        local: true,
        uri: nil
      })

    s
  end

  describe "notify/1" do
    test "inserts a notification" do
      a = local!("a")
      b = local!("b")
      s = insert_status!(b)

      assert {:ok, %Notification{type: "favourite"}} =
               Notifications.notify(%{
                 recipient_id: b.id,
                 account_id: a.id,
                 type: "favourite",
                 status_id: s.id
               })
    end

    test "is idempotent on (recipient, type, account, status)" do
      a = local!("a")
      b = local!("b")
      s = insert_status!(b)

      attrs = %{recipient_id: b.id, account_id: a.id, type: "favourite", status_id: s.id}
      Notifications.notify(attrs)
      assert :noop = Notifications.notify(attrs)

      assert Repo.aggregate(Notification, :count) == 1
    end

    test "skips self-notifications" do
      a = local!("a")
      s = insert_status!(a)

      assert :noop =
               Notifications.notify(%{
                 recipient_id: a.id,
                 account_id: a.id,
                 type: "favourite",
                 status_id: s.id
               })
    end

    test "skips when recipient is remote" do
      {:ok, remote} =
        Profiles.create_profile(%{
          username: "remote",
          domain: "elsewhere.test",
          remote_url: "http://elsewhere.test/users/remote",
          inbox_url: "http://elsewhere.test/users/remote/inbox",
          public_key_pem: "stub"
        })

      a = local!("a")

      assert :noop =
               Notifications.notify(%{
                 recipient_id: remote.id,
                 account_id: a.id,
                 type: "favourite"
               })
    end

    test "follow_request notifications dedupe even with status_id NULL" do
      a = local!("a")
      b = local!("b")

      attrs = %{recipient_id: b.id, account_id: a.id, type: "follow_request"}
      Notifications.notify(attrs)
      assert :noop = Notifications.notify(attrs)
    end
  end

  describe "producer hooks" do
    test "favourite generates a notification for the status author" do
      a = local!("a")
      b = local!("b")
      s = insert_status!(b)

      Statuses.favourite(a, s)

      assert [%Notification{type: "favourite", account_id: aid, recipient_id: bid}] =
               Repo.all(Notification)

      assert aid == a.id
      assert bid == b.id
    end

    test "reblog generates a notification" do
      a = local!("a")
      b = local!("b")
      s = insert_status!(b)

      Statuses.reblog(a, s)

      assert [%Notification{type: "reblog"}] = Repo.all(Notification)
    end

    test "local follow generates a follow notification" do
      a = local!("a")
      b = local!("b")

      Follows.follow(a, b)

      assert [%Notification{type: "follow", recipient_id: rid, account_id: aid}] =
               Repo.all(Notification)

      assert rid == b.id
      assert aid == a.id
    end

    test "follow against a locked target generates a follow_request notification" do
      a = local!("a")

      {:ok, b} =
        Profiles.create_profile(%{username: "b_locked", is_private: true})

      Follows.follow(a, b)

      assert [%Notification{type: "follow_request"}] = Repo.all(Notification)
    end

    test "local mention in status generates a mention notification" do
      a = local!("a")
      _b = local!("b")

      {:ok, _s} =
        Statuses.create_local(a, %{
          "status" => "hello @b how are you?",
          "visibility" => "public"
        })

      assert [%Notification{type: "mention"}] = Repo.all(Notification)
    end

    test "self-favourite produces no notification" do
      a = local!("a")
      s = insert_status!(a)

      Statuses.favourite(a, s)

      assert Repo.aggregate(Notification, :count) == 0
    end
  end

  describe "list/2" do
    test "returns most-recent first, paginated" do
      a = local!("a")
      b = local!("b")

      for i <- 1..5 do
        s = insert_status!(b)
        Statuses.favourite(local!("u#{i}"), s)
        # Also a notification for b from a:
        Notifications.notify(%{
          recipient_id: b.id,
          account_id: a.id,
          type: "favourite",
          status_id: s.id
        })
      end

      {rows, _} = Notifications.list(b.id, %{"limit" => "3"})
      assert length(rows) == 3

      ids = Enum.map(rows, & &1.id)
      assert ids == Enum.sort(ids, :desc)
    end

    test "filters by types" do
      a = local!("a")
      b = local!("b")
      s = insert_status!(b)

      Notifications.notify(%{
        recipient_id: b.id,
        account_id: a.id,
        type: "favourite",
        status_id: s.id
      })

      Notifications.notify(%{recipient_id: b.id, account_id: a.id, type: "follow"})

      {rows, _} = Notifications.list(b.id, %{"types" => ["follow"]})
      assert [%Notification{type: "follow"}] = rows
    end

    test "excludes dismissed" do
      a = local!("a")
      b = local!("b")
      s = insert_status!(b)

      {:ok, n} =
        Notifications.notify(%{
          recipient_id: b.id,
          account_id: a.id,
          type: "favourite",
          status_id: s.id
        })

      Notifications.dismiss(b.id, n.id)
      {rows, _} = Notifications.list(b.id, %{})
      assert rows == []
    end
  end

  describe "dismiss/2 and clear/1" do
    test "dismiss/2 hides only the targeted notification" do
      a = local!("a")
      b = local!("b")
      s1 = insert_status!(b)
      s2 = insert_status!(b)

      {:ok, n1} =
        Notifications.notify(%{
          recipient_id: b.id,
          account_id: a.id,
          type: "favourite",
          status_id: s1.id
        })

      {:ok, _n2} =
        Notifications.notify(%{
          recipient_id: b.id,
          account_id: a.id,
          type: "favourite",
          status_id: s2.id
        })

      Notifications.dismiss(b.id, n1.id)
      {rows, _} = Notifications.list(b.id, %{})
      assert length(rows) == 1
    end

    test "clear/1 dismisses all" do
      a = local!("a")
      b = local!("b")
      s = insert_status!(b)

      Notifications.notify(%{
        recipient_id: b.id,
        account_id: a.id,
        type: "favourite",
        status_id: s.id
      })

      Notifications.clear(b.id)
      {rows, _} = Notifications.list(b.id, %{})
      assert rows == []
    end
  end
end
