defmodule Angler.Federation.FollowersSyncTest do
  @moduledoc "FEP-8fcf followers collection synchronization."

  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.Federation.{FollowersSync, HTTPSignature, HttpSignatureKey}
  alias Angler.Federation.Workers.FollowDeliver
  alias Angler.Federation.Workers.FollowersSync, as: SyncWorker
  alias Angler.Follows
  alias Angler.Follows.Follower
  alias Angler.Profiles
  alias Angler.Profiles.Keypair
  alias Angler.Repo

  setup do
    [alice, carol] =
      for name <- ~w(alice carol) do
        {:ok, %{profile: p}} =
          Accounts.register(%{
            username: name,
            email: "#{name}@example.com",
            password: "passwordOK1"
          })

        p
      end

    {pub, priv} = Keypair.generate()

    {:ok, bob} =
      Profiles.create_profile(%{
        username: "bob",
        domain: "remote.test",
        remote_url: "http://remote.test/users/bob",
        inbox_url: "http://remote.test/users/bob/inbox",
        followers_url: "http://remote.test/users/bob/followers",
        public_key_pem: pub
      })

    %{alice: alice, carol: carol, bob: bob, bob_priv: priv, bob_pub: pub}
  end

  defp header_for(digest) do
    ~s(collectionId="http://remote.test/users/bob/followers", url="http://remote.test/users/bob/followers_synchronization", digest="#{digest}")
  end

  defp signed_headers(
         value,
         signed \\ "(request-target) host date digest collection-synchronization"
       ) do
    %{
      "collection-synchronization" => value,
      "signature" =>
        ~s(keyId="http://remote.test/users/bob#main-key",headers="#{signed}",signature="x")
    }
  end

  # local `follower` follows remote `followee`, accepted `age_s` seconds ago.
  defp follows!(follower, followee, age_s \\ 3600) do
    at = DateTime.add(DateTime.utc_now(), -age_s)

    Repo.insert!(%Follower{
      profile_id: followee.id,
      following_id: follower.id,
      accepted_at: at,
      remote_url: "http://example.com/follows/#{follower.id}",
      inserted_at: at,
      updated_at: at
    })
  end

  test "digest and header parsing" do
    assert FollowersSync.digest([]) == String.duplicate("0", 64)
    # XOR is order-independent and self-cancelling.
    assert FollowersSync.digest(["a", "b"]) == FollowersSync.digest(["b", "a"])
    assert FollowersSync.digest(["a", "a"]) == FollowersSync.digest([])

    assert FollowersSync.authority("HTTPS://Example.com:443/x") == "https://example.com"
    assert FollowersSync.authority("http://example.com:8080/x") == "http://example.com:8080"
    assert FollowersSync.authority("ftp://example.com") == nil

    assert {:ok, %{digest: d}} = FollowersSync.parse_header(header_for(String.duplicate("A", 64)))
    assert d == String.duplicate("a", 64)
    assert FollowersSync.parse_header(~s(collectionId="x", url="y", digest="short")) == :error
  end

  test "outbound header digests the followers on the receiving server", ctx do
    {:ok, :accepted, _} = Follows.insert_inbound_follow(ctx.alice.id, ctx.bob.id)

    value = FollowersSync.header(ctx.alice, "http://remote.test/inbox")
    {:ok, params} = FollowersSync.parse_header(value)
    assert params.digest == FollowersSync.digest([ctx.bob.remote_url])
    assert params.collection_id == Profiles.actor_url(ctx.alice) <> "/followers"

    {:ok, other} =
      FollowersSync.parse_header(FollowersSync.header(ctx.alice, "https://elsewhere.test/inbox"))

    assert other.digest == String.duplicate("0", 64)

    assert FollowersSync.header(ctx.alice, AnglerWeb.Endpoint.url() <> "/f/inbox") == nil
  end

  test "an inbound digest that disagrees queues a sync, once; agreement doesn't", ctx do
    follows!(ctx.alice, ctx.bob)
    ours = FollowersSync.digest([Profiles.actor_url(ctx.alice)])

    FollowersSync.handle_inbound(signed_headers(header_for(ours)), ctx.bob.remote_url)
    refute_enqueued(worker: SyncWorker)

    # Unsigned, or from someone else's collection: ignored.
    FollowersSync.handle_inbound(
      signed_headers(header_for(String.duplicate("0", 64)), "(request-target) host date digest"),
      ctx.bob.remote_url
    )

    refute_enqueued(worker: SyncWorker)

    FollowersSync.handle_inbound(
      signed_headers(header_for(String.duplicate("0", 64))),
      ctx.bob.remote_url
    )

    FollowersSync.handle_inbound(
      signed_headers(header_for(String.duplicate("1", 64))),
      ctx.bob.remote_url
    )

    assert [_] = all_enqueued(worker: SyncWorker)
  end

  describe "synchronize" do
    setup do
      Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})
      on_exit(fn -> Application.delete_env(:angler, :req_options) end)
      Req.Test.set_req_test_to_shared(self())
      :ok
    end

    defp serve(items) do
      Req.Test.stub(:angler_http, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "http://remote.test/users/bob/followers_synchronization",
            "type" => "OrderedCollection",
            "orderedItems" => items
          })
        )
      end)
    end

    defp sync(ctx, items) do
      FollowersSync.synchronize(
        Repo.reload!(ctx.bob),
        "http://remote.test/users/bob/followers",
        "http://remote.test/users/bob/followers_synchronization",
        FollowersSync.digest(items)
      )
    end

    test "drops follows they don't list, but not brand new ones", ctx do
      follows!(ctx.alice, ctx.bob)
      follows!(ctx.carol, ctx.bob, 30)
      serve([])

      assert %{status: :synchronized, removed: 1} = sync(ctx, [])
      refute Follows.get_follower(ctx.bob.id, ctx.alice.id)
      assert Follows.get_follower(ctx.bob.id, ctx.carol.id)
    end

    test "accepts a pending follow they list; undoes one we don't have", ctx do
      Repo.insert!(%Follower{
        profile_id: ctx.bob.id,
        following_id: ctx.alice.id,
        pending_remote: true,
        remote_url: "http://example.com/follows/pending"
      })

      items = [Profiles.actor_url(ctx.alice), Profiles.actor_url(ctx.carol)]
      serve(items)

      assert %{accepted: 1, undone: 1} = sync(ctx, items)
      assert %Follower{accepted_at: %DateTime{}} = Follows.get_follower(ctx.bob.id, ctx.alice.id)

      assert [%{args: %{"verb" => "undo", "local_actor_id" => cid}}] =
               all_enqueued(worker: FollowDeliver)

      assert cid == ctx.carol.id
    end

    test "a list that doesn't match the signed digest removes nothing", ctx do
      follows!(ctx.alice, ctx.bob)
      serve([])

      assert %{status: :synchronized_without_removals, removed: 0} =
               FollowersSync.synchronize(
                 Repo.reload!(ctx.bob),
                 "http://remote.test/users/bob/followers",
                 "http://remote.test/users/bob/followers_synchronization",
                 String.duplicate("1", 64)
               )

      assert Follows.get_follower(ctx.bob.id, ctx.alice.id)
    end

    test "a sync URL off the sender's server is refused", ctx do
      assert %{status: :skipped} =
               FollowersSync.synchronize(
                 Repo.reload!(ctx.bob),
                 "http://remote.test/users/bob/followers",
                 "http://evil.test/list",
                 String.duplicate("1", 64)
               )
    end
  end

  describe "GET /users/:username/followers_synchronization" do
    test "lists the signer's server's followers only", %{conn: conn} = ctx do
      {:ok, :accepted, _} = Follows.insert_inbound_follow(ctx.alice.id, ctx.bob.id)

      Repo.insert!(%HttpSignatureKey{
        key_id: "http://remote.test/users/bob#main-key",
        owner_url: ctx.bob.remote_url,
        public_key_pem: ctx.bob_pub,
        fetched_at: DateTime.utc_now()
      })

      path = "/users/alice/followers_synchronization"

      {:ok, headers} =
        HTTPSignature.sign(
          :get,
          path,
          "www.example.com",
          "",
          "http://remote.test/users/bob#main-key",
          ctx.bob_priv,
          [{"Accept", "application/activity+json"}]
        )

      signed =
        headers
        |> Enum.reject(fn {k, _} -> String.downcase(k) == "host" end)
        |> Enum.reduce(conn, fn {k, v}, c -> put_req_header(c, String.downcase(k), v) end)

      body = signed |> get(path) |> json_response(200)
      assert body["orderedItems"] == [ctx.bob.remote_url]

      assert conn |> get(path) |> json_response(401)
    end
  end
end
