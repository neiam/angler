defmodule Angler.Push.DeliverTest do
  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.Notifications
  alias Angler.OAuth
  alias Angler.Profiles
  alias Angler.Push
  alias Angler.Push.Sender
  alias Angler.Push.Workers.PushDeliver
  alias Angler.Statuses

  setup do
    Sender.Test.clear()

    {:ok, %{user: u, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: c} = OAuth.first_party_client!()
    {:ok, %{token: token}} = OAuth.issue_token(u, c, scopes: ["read"])

    {:ok, _sub} =
      Push.subscribe(token, %{
        "subscription" => %{
          "endpoint" => "https://push.example/abc",
          "keys" => %{
            "p256dh" => Base.url_encode64(:crypto.strong_rand_bytes(65), padding: false),
            "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
          }
        },
        "data" => %{
          "alerts" => %{
            "favourite" => "true",
            "mention" => "true",
            "follow" => "false"
          },
          "policy" => "all"
        }
      })

    %{alice: alice, token: token}
  end

  test "favourite by another user fans out to subscriber", ctx do
    {:ok, %{profile: bob}} =
      Accounts.register(%{
        username: "bob",
        email: "bob@example.com",
        password: "passwordOK1"
      })

    {:ok, status} = Statuses.create_local(ctx.alice, %{"status" => "x", "visibility" => "public"})

    Statuses.favourite(bob, status)

    assert_enqueued(worker: PushDeliver)
    drain = Oban.drain_queue(queue: :notifications)
    assert drain.failure == 0

    [{body, sub}] = Sender.Test.sent()
    payload = Jason.decode!(body)

    assert payload["notification_type"] == "favourite"
    assert payload["title"] =~ "favourited"
    assert sub.endpoint == "https://push.example/abc"
  end

  test "alerts filter excludes notifications the subscriber didn't opt in to", ctx do
    # `follow` is false in the subscription's alerts above.
    {:ok, %{profile: bob}} =
      Accounts.register(%{
        username: "bob",
        email: "bob@example.com",
        password: "passwordOK1"
      })

    Angler.Follows.follow(bob, ctx.alice)

    Oban.drain_queue(queue: :notifications)
    assert [] = Sender.Test.sent()
  end

  test "alerts respect mention type", ctx do
    other = Profiles.create_profile(%{username: "carol"}) |> elem(1)

    {:ok, _} =
      Accounts.register(%{username: "carol2", email: "c@example.com", password: "passwordOK1"})

    Notifications.notify(%{
      recipient_id: ctx.alice.id,
      account_id: other.id,
      type: "mention",
      status_id: nil
    })

    Oban.drain_queue(queue: :notifications)

    [{body, _}] = Sender.Test.sent()
    payload = Jason.decode!(body)
    assert payload["notification_type"] == "mention"
  end

  test "no subscription → no jobs enqueued", ctx do
    Push.unsubscribe(ctx.token)

    {:ok, %{profile: bob}} =
      Accounts.register(%{
        username: "bob",
        email: "bob@example.com",
        password: "passwordOK1"
      })

    {:ok, status} = Statuses.create_local(ctx.alice, %{"status" => "x", "visibility" => "public"})
    Statuses.favourite(bob, status)

    refute_enqueued(worker: PushDeliver)
    assert [] = Sender.Test.sent()
  end

  test "policy=followed only fires for accounts alice follows", ctx do
    Push.update_alerts(ctx.token, %{
      "data" => %{
        "alerts" => %{"favourite" => "true"},
        "policy" => "followed"
      }
    })

    {:ok, %{profile: stranger}} =
      Accounts.register(%{
        username: "stranger",
        email: "stranger@example.com",
        password: "passwordOK1"
      })

    {:ok, %{profile: friend}} =
      Accounts.register(%{
        username: "friend",
        email: "friend@example.com",
        password: "passwordOK1"
      })

    Angler.Follows.follow(ctx.alice, friend)

    {:ok, status} = Statuses.create_local(ctx.alice, %{"status" => "x", "visibility" => "public"})
    Statuses.favourite(stranger, status)
    Statuses.favourite(friend, status)

    Oban.drain_queue(queue: :notifications)

    sends = Sender.Test.sent()
    bodies = Enum.map(sends, fn {b, _} -> Jason.decode!(b) end)
    titles = Enum.map(bodies, & &1["title"])

    assert Enum.any?(titles, &(&1 =~ "friend"))
    refute Enum.any?(titles, &(&1 =~ "stranger"))
  end
end
