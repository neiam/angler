defmodule Angler.StreamingTest do
  use Angler.DataCase, async: false

  alias Angler.Notifications
  alias Angler.Profiles
  alias Angler.Statuses
  alias Angler.Streaming

  defp local!(name), do: Profiles.create_profile(%{username: name}) |> elem(1)

  test "broadcast_notification reaches a subscriber on the user topic" do
    alice = local!("alice")
    bob = local!("bob")

    :ok = Streaming.subscribe("user:#{alice.id}")

    {:ok, _} =
      Notifications.notify(%{
        recipient_id: alice.id,
        account_id: bob.id,
        type: "follow"
      })

    assert_receive {:streaming, topic, "notification", payload}, 500
    assert topic == "user:#{alice.id}"

    decoded = Jason.decode!(payload)
    assert decoded["type"] == "follow"
  end

  test "broadcast_status_update reaches public subscribers when status is :public" do
    alice = local!("alice")
    :ok = Streaming.subscribe("public")
    :ok = Streaming.subscribe("public:local")

    {:ok, _status} =
      Statuses.create_local(alice, %{"status" => "hello world", "visibility" => "public"})

    assert_receive {:streaming, "public", "update", payload}, 500
    assert_receive {:streaming, "public:local", "update", _}, 500

    decoded = Jason.decode!(payload)
    assert decoded["content"] =~ "hello world"
    assert decoded["visibility"] == "public"
  end

  test "private status does not hit the public stream" do
    alice = local!("alice")
    :ok = Streaming.subscribe("public")

    {:ok, _} =
      Statuses.create_local(alice, %{"status" => "shh", "visibility" => "private"})

    refute_receive {:streaming, "public", _, _}, 200
  end

  test "delete event sends the id-string payload" do
    alice = local!("alice")
    :ok = Streaming.subscribe("user:#{alice.id}")

    {:ok, status} =
      Statuses.create_local(alice, %{"status" => "x", "visibility" => "public"})

    {:ok, _} = Statuses.delete_local(status.id, alice)

    # Drain the create event first.
    assert_receive {:streaming, _, "update", _}, 500
    assert_receive {:streaming, _, "delete", payload}, 500

    assert Jason.decode!(payload) == Integer.to_string(status.id)
  end

  test "edit fires status.update on the user stream" do
    alice = local!("alice")
    :ok = Streaming.subscribe("user:#{alice.id}")

    {:ok, status} =
      Statuses.create_local(alice, %{"status" => "before", "visibility" => "public"})

    {:ok, _} = Statuses.update_local(status.id, alice, %{"status" => "after"})

    assert_receive {:streaming, _, "update", _}, 500
    assert_receive {:streaming, _, "status.update", payload}, 500

    decoded = Jason.decode!(payload)
    assert decoded["content"] =~ "after"
  end
end
