defmodule Angler.QuotesTest do
  @moduledoc "FEP-044f: QuoteRequests for local posts, stamps and revocation."

  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.Accounts.Settings
  alias Angler.Federation.NoteBuilder
  alias Angler.Federation.Workers.{ActivityHandler, DeleteWorker}
  alias Angler.Follows
  alias Angler.Profiles
  alias Angler.Quotes
  alias Angler.Quotes.Authorization
  alias Angler.Quotes.Workers.QuoteDeliver
  alias Angler.Repo
  alias Angler.Statuses

  setup do
    {:ok, %{user: user, profile: alice}} =
      Accounts.register(%{username: "alice", email: "alice@example.com", password: "passwordOK1"})

    {:ok, post} = Statuses.create_local(alice, %{"status" => "quote me"}, broadcast: false)

    {:ok, bob} =
      Profiles.create_profile(%{
        username: "bob",
        domain: "remote.test",
        remote_url: "http://remote.test/users/bob",
        inbox_url: "http://remote.test/users/bob/inbox",
        public_key_pem: "stub"
      })

    %{alice: alice, user: user, post: post, bob: bob}
  end

  @quote_url "http://remote.test/notes/q1"

  defp request(ctx, extra) do
    Map.merge(
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "http://remote.test/requests/1",
        "type" => "QuoteRequest",
        "actor" => ctx.bob.remote_url,
        "object" => ctx.post.url,
        "instrument" => @quote_url
      },
      extra
    )
  end

  defp handle(ctx, extra \\ %{}) do
    perform_job(ActivityHandler, %{
      "payload" => request(ctx, extra),
      "actor_url" => ctx.bob.remote_url,
      "recipient_id" => ctx.alice.id
    })
  end

  defp answers do
    for job <- all_enqueued(worker: QuoteDeliver), do: job.args["activity"]
  end

  test "a public post is approved: Accept carries a stamp the URL serves", %{conn: conn} = ctx do
    :ok = handle(ctx)

    assert [%{"type" => "Accept", "result" => stamp_url} = accept] = answers()
    assert accept["object"]["instrument"] == @quote_url
    assert accept["to"] == ctx.bob.remote_url

    path = URI.parse(stamp_url).path
    stamp = conn |> get(path) |> json_response(200)
    assert stamp["type"] == "QuoteAuthorization"
    assert stamp["interactingObject"] == @quote_url
    assert stamp["interactionTarget"] == ctx.post.url

    # Asking again reuses the stamp.
    :ok = handle(ctx, %{"id" => "http://remote.test/requests/2"})
    assert Repo.aggregate(Authorization, :count) == 1
  end

  test "policy nobody, or followers for a non-follower, is a Reject", ctx do
    {:ok, _} = Settings.merge_account(ctx.user.id, %{"can_quote" => "followers"})
    :ok = handle(ctx)
    assert [%{"type" => "Reject"}] = answers()

    # A follower gets in.
    {:ok, :accepted, _} = Follows.insert_inbound_follow(ctx.alice.id, ctx.bob.id)
    :ok = handle(ctx, %{"id" => "http://remote.test/requests/2"})
    assert Enum.any?(answers(), &(&1["type"] == "Accept"))

    # A per-post nobody overrides the account default.
    {:ok, _} = Statuses.set_quote_policy(ctx.post.id, ctx.alice, "nobody")

    :ok =
      handle(ctx, %{"id" => "http://remote.test/requests/3", "instrument" => @quote_url <> "x"})

    assert Repo.aggregate(Authorization, :count) == 1
  end

  test "private posts, forged hosts and wrong instruments get no answer", ctx do
    {:ok, private} =
      Statuses.create_local(ctx.alice, %{"status" => "f/o", "visibility" => "private"},
        broadcast: false
      )

    :ok = handle(ctx, %{"object" => private.url})
    :ok = handle(ctx, %{"id" => "http://evil.test/requests/1"})
    :ok = handle(ctx, %{"instrument" => "http://evil.test/notes/1"})
    assert answers() == []

    # An inlined quote post must be the requester's, quoting this post.
    :ok =
      handle(ctx, %{
        "instrument" => %{
          "id" => @quote_url,
          "attributedTo" => "http://remote.test/users/carol",
          "quote" => ctx.post.url
        }
      })

    assert [%{"type" => "Reject"}] = answers()
  end

  test "revoking: Delete is sent, the stamp is gone, a repeat is refused", %{conn: conn} = ctx do
    :ok = handle(ctx)
    [auth] = Repo.all(Authorization)

    :ok = Quotes.revoke(ctx.alice.id, auth.id)

    assert %{"type" => "Delete", "object" => %{"type" => "QuoteAuthorization"}} =
             Enum.find(answers(), &(&1["type"] == "Delete"))

    path = URI.parse(Quotes.stamp_url(auth)).path
    assert conn |> get(path) |> json_response(410)

    :ok = handle(ctx, %{"id" => "http://remote.test/requests/2"})
    assert Enum.count(answers(), &(&1["type"] == "Reject")) == 1
  end

  test "blocking the quoter revokes; deleting the quote forgets it", ctx do
    :ok = handle(ctx)
    {:ok, _} = Profiles.BlocksMutes.block(ctx.alice, ctx.bob)
    assert [%Authorization{state: "revoked"}] = Repo.all(Authorization)

    Repo.delete_all(Authorization)
    :ok = Profiles.BlocksMutes.unblock(ctx.alice, ctx.bob)
    :ok = handle(ctx, %{"id" => "http://remote.test/requests/2"})
    assert [%Authorization{state: "approved"}] = Repo.all(Authorization)

    perform_job(DeleteWorker, %{
      "activity" => %{
        "type" => "Delete",
        "actor" => ctx.bob.remote_url,
        "object" => %{"type" => "Tombstone", "id" => @quote_url}
      }
    })

    assert Repo.all(Authorization) == []
  end

  test "deleting the quoted post revokes its stamps", ctx do
    :ok = handle(ctx)
    {:ok, _} = Statuses.delete_local(ctx.post.id, ctx.alice)
    assert Repo.all(Authorization) == []
    assert Enum.any?(answers(), &(&1["type"] == "Delete"))
  end

  test "our Notes carry interactionPolicy.canQuote", ctx do
    note = NoteBuilder.object(ctx.post)

    assert note["interactionPolicy"]["canQuote"]["automaticApproval"] == [
             "https://www.w3.org/ns/activitystreams#Public"
           ]

    assert Enum.any?(note["@context"], &(is_map(&1) and Map.has_key?(&1, "canQuote")))

    {:ok, _} = Statuses.set_quote_policy(ctx.post.id, ctx.alice, "nobody")
    note = NoteBuilder.object(Statuses.get(ctx.post.id))

    assert note["interactionPolicy"]["canQuote"]["automaticApproval"] == [
             Profiles.actor_url(ctx.alice)
           ]
  end

  describe "API" do
    setup ctx do
      %{client: c} = Angler.OAuth.first_party_client!()
      {:ok, %{access: t}} = Angler.OAuth.issue_token(ctx.user, c, scopes: ["read", "write"])
      %{token: t}
    end

    defp api(conn, ctx), do: put_req_header(conn, "authorization", "Bearer " <> ctx.token)

    test "quote_approval_policy on create, and PUT interaction_policy", %{conn: conn} = ctx do
      %{"id" => id} =
        conn
        |> api(ctx)
        |> post(~p"/api/v1/statuses", %{"status" => "hi", "quote_approval_policy" => "nobody"})
        |> json_response(200)

      assert Statuses.get(String.to_integer(id)).quote_policy == 0

      assert conn
             |> api(ctx)
             |> post(~p"/api/v1/statuses", %{"status" => "x", "quote_approval_policy" => "all"})
             |> json_response(422)

      assert %{"id" => ^id, "quote_approval_policy" => "followers"} =
               conn
               |> api(ctx)
               |> put(~p"/api/v1/statuses/#{id}/interaction_policy", %{
                 "quote_approval_policy" => "followers"
               })
               |> json_response(200)

      # null clears back to the account default.
      assert %{"quote_approval_policy" => "public"} =
               conn
               |> api(ctx)
               |> put_req_header("content-type", "application/json")
               |> put(
                 ~p"/api/v1/statuses/#{id}/interaction_policy",
                 ~s({"quote_approval_policy":null})
               )
               |> json_response(200)

      # Not someone else's post.
      {:ok, other} =
        Accounts.register(%{username: "carol", email: "c@example.com", password: "passwordOK1"})

      {:ok, theirs} =
        Statuses.create_local(other.profile, %{"status" => "mine"}, broadcast: false)

      assert conn
             |> api(ctx)
             |> put(~p"/api/v1/statuses/#{theirs.id}/interaction_policy", %{
               "quote_approval_policy" => "nobody"
             })
             |> json_response(404)
    end

    test "source[quote_policy] sets the account default", %{conn: conn} = ctx do
      creds =
        conn
        |> api(ctx)
        |> patch(~p"/api/v1/accounts/update_credentials", %{
          "source" => %{"quote_policy" => "followers"}
        })
        |> json_response(200)

      assert creds["source"]["quote_policy"] == "followers"
      assert Quotes.account_policy(ctx.alice) == "followers"
      assert Quotes.api_policy(ctx.post) == "followers"
    end
  end
end
