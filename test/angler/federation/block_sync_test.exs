defmodule Angler.Federation.BlockSyncTest do
  @moduledoc "FEP-070c block synchronization."

  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.Federation.{BlockSync, HTTPSignature, HttpSignatureKey, Instance}
  alias Angler.Federation.Workers.{BlockDeliver, BlockSyncReconcile}
  alias Angler.Federation.Workers.BlockSync, as: SyncWorker
  alias Angler.Profiles
  alias Angler.Profiles.{Block, BlocksMutes, Keypair}
  alias Angler.Repo

  @sync_url "http://remote.test/f/block_sync"

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

    [bob, dave] =
      for name <- ~w(bob dave) do
        {:ok, p} =
          Profiles.create_profile(%{
            username: name,
            domain: "remote.test",
            remote_url: "http://remote.test/users/#{name}",
            inbox_url: "http://remote.test/users/#{name}/inbox",
            public_key_pem: pub
          })

        p
      end

    {:ok, eve} =
      Profiles.create_profile(%{
        username: "eve",
        domain: "elsewhere.test",
        remote_url: "http://elsewhere.test/users/eve",
        inbox_url: "http://elsewhere.test/users/eve/inbox"
      })

    instance = Repo.insert!(%Instance{domain: "remote.test"})

    %{
      alice: alice,
      carol: carol,
      bob: bob,
      dave: dave,
      eve: eve,
      instance: instance,
      priv: priv,
      pub: pub
    }
  end

  defp aid(%{username: u, domain: nil}), do: AnglerWeb.Endpoint.url() <> "/users/" <> u
  defp aid(%{remote_url: r}), do: r

  defp signed_headers(value, signed \\ "(request-target) host date digest block-synchronization") do
    %{
      "block-synchronization" => value,
      "signature" =>
        ~s(keyId="http://remote.test/users/bob#main-key",headers="#{signed}",signature="x")
    }
  end

  # remote `blocker` blocks local `blocked`, `age_s` seconds ago.
  defp remote_block!(blocker, blocked, age_s \\ 3600) do
    at = DateTime.add(DateTime.utc_now(), -age_s)

    Repo.insert!(%Block{
      profile_id: blocker.id,
      target_id: blocked.id,
      inserted_at: at,
      updated_at: at
    })
  end

  defp stub_http(routes) do
    Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})
    on_exit(fn -> Application.delete_env(:angler, :req_options) end)
    Req.Test.set_req_test_to_shared(self())
    test = self()

    Req.Test.stub(:angler_http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:http, conn.method, conn.request_path, conn.req_headers, body})

      case routes[conn.request_path] do
        nil ->
          Plug.Conn.send_resp(conn, 202, "")

        doc ->
          conn
          |> Plug.Conn.put_resp_content_type("application/activity+json")
          |> Plug.Conn.send_resp(200, Jason.encode!(doc))
      end
    end)
  end

  defp collection(pairs, opts \\ []) do
    digest = Keyword.get(opts, :digest, BlockSync.digest(pairs))

    %{
      "id" => @sync_url,
      "type" => "OrderedCollection",
      "blockSynchronizationDigest" => digest,
      "orderedItems" =>
        Enum.map(pairs, fn {a, o} -> %{"type" => "Block", "actor" => a, "object" => o} end)
    }
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  test "digest and header parsing" do
    assert BlockSync.digest([]) == String.duplicate("0", 64)

    assert BlockSync.digest([{"a", "b"}, {"c", "d"}]) ==
             BlockSync.digest([{"c", "d"}, {"a", "b"}])

    refute BlockSync.digest([{"a", "b"}]) == BlockSync.digest([{"b", "a"}])

    assert {:ok, %{url: @sync_url, digest: d}} =
             BlockSync.parse_header(~s(url="#{@sync_url}", digest="#{String.duplicate("A", 64)}"))

    assert d == String.duplicate("a", 64)
    assert BlockSync.parse_header(~s(url="x", digest="short")) == :error
    assert BlockSync.parse_header(~s(url="x", url="y", digest="#{d}")) == :error
  end

  describe "disclosing" do
    test "a peer hears only of blocks of its own actors", ctx do
      {:ok, _} = BlocksMutes.block(ctx.alice, ctx.bob)
      {:ok, _} = BlocksMutes.block(ctx.carol, ctx.eve)

      pairs = [{aid(ctx.alice), aid(ctx.bob)}]
      assert BlockSync.disclosed_pairs("http://remote.test") == pairs

      assert {:ok, %{url: url, digest: digest}} =
               BlockSync.parse_header(BlockSync.header("http://remote.test/inbox"))

      assert url == AnglerWeb.Endpoint.url() <> "/f/block_sync"
      assert digest == BlockSync.digest(pairs)

      assert BlockSync.header(AnglerWeb.Endpoint.url() <> "/f/inbox") == nil

      ctx.instance |> Ecto.Changeset.change(unlisted: true) |> Repo.update!()
      assert BlockSync.header("http://remote.test/inbox") == nil
    end

    test "blocking a remote actor sends Block, unblocking sends Undo Block", ctx do
      stub_http(%{})
      {:ok, block} = BlocksMutes.block(ctx.alice, ctx.bob)

      assert [%{args: args}] = all_enqueued(worker: BlockDeliver)
      assert args["undo"] == false
      assert :ok = perform_job(BlockDeliver, args)

      assert_receive {:http, "POST", "/users/bob/inbox", headers, body}

      assert %{"type" => "Block", "object" => "http://remote.test/users/bob"} =
               Jason.decode!(body)

      assert {"block-synchronization", _} = List.keyfind(headers, "block-synchronization", 0)

      :ok = BlocksMutes.unblock(ctx.alice, ctx.bob)
      undo = %{args | "undo" => true, "block_id" => block.id}
      assert :ok = perform_job(BlockDeliver, undo)
      assert_receive {:http, "POST", "/users/bob/inbox", _, body}

      assert %{"type" => "Undo", "object" => %{"type" => "Block"}} = Jason.decode!(body)

      # The block was lifted before the queued Block went out: nothing sent.
      assert :ok = perform_job(BlockDeliver, args)
      refute_receive {:http, _, _, _, _}
    end

    test "local blocks of local profiles aren't federated", ctx do
      {:ok, _} = BlocksMutes.block(ctx.alice, ctx.carol)
      refute_enqueued(worker: BlockDeliver)
    end
  end

  describe "receiving" do
    test "a disagreeing digest queues a sync and remembers the endpoint", ctx do
      remote_block!(ctx.bob, ctx.alice)
      ours = BlockSync.digest([{aid(ctx.bob), aid(ctx.alice)}])

      BlockSync.handle_inbound(
        signed_headers(~s(url="#{@sync_url}", digest="#{ours}")),
        ctx.bob.remote_url
      )

      refute_enqueued(worker: SyncWorker)
      assert Repo.reload!(ctx.instance).block_sync_url == @sync_url

      # Unsigned, or pointing off their server: ignored.
      zero = String.duplicate("0", 64)

      BlockSync.handle_inbound(
        signed_headers(~s(url="#{@sync_url}", digest="#{zero}"), "(request-target) host date"),
        ctx.bob.remote_url
      )

      BlockSync.handle_inbound(
        signed_headers(~s(url="http://evil.test/list", digest="#{zero}")),
        ctx.bob.remote_url
      )

      refute_enqueued(worker: SyncWorker)

      for d <- [zero, String.duplicate("1", 64)] do
        BlockSync.handle_inbound(
          signed_headers(~s(url="#{@sync_url}", digest="#{d}")),
          ctx.bob.remote_url
        )
      end

      assert [%{args: %{"digest" => latest}}] = all_enqueued(worker: SyncWorker)
      assert latest == String.duplicate("1", 64)
    end

    test "after a failed fetch, headers don't queue syncs for a while", ctx do
      :ok = BlockSync.back_off("http://remote.test")

      BlockSync.handle_inbound(
        signed_headers(~s(url="#{@sync_url}", digest="#{String.duplicate("1", 64)}")),
        ctx.bob.remote_url
      )

      refute_enqueued(worker: SyncWorker)
    end

    test "inbound Block is ignored when receiving is off", ctx do
      Application.put_env(:angler, BlockSync, enabled: false)
      on_exit(fn -> Application.delete_env(:angler, BlockSync) end)

      block = %{"type" => "Block", "actor" => aid(ctx.bob), "object" => aid(ctx.alice)}
      assert :ok = Profiles.Federation.handle_block(block, aid(ctx.bob))
      refute BlocksMutes.blocked?(ctx.bob.id, ctx.alice.id)
    end
  end

  describe "synchronize" do
    test "applies listed blocks and lifts stale ones, but not new ones", ctx do
      remote_block!(ctx.bob, ctx.carol)
      remote_block!(ctx.dave, ctx.carol, 30)
      pairs = [{aid(ctx.bob), aid(ctx.alice)}]
      stub_http(%{"/f/block_sync" => collection(pairs)})

      assert %{status: :synchronized, added: 1, removed: 1} =
               BlockSync.synchronize("http://remote.test", @sync_url, String.duplicate("1", 64))

      assert BlocksMutes.blocked?(ctx.bob.id, ctx.alice.id)
      refute BlocksMutes.blocked?(ctx.bob.id, ctx.carol.id)
      assert BlocksMutes.blocked?(ctx.dave.id, ctx.carol.id)

      # Now in agreement: no fetch.
      ours = BlockSync.received_digest("http://remote.test")
      assert %{status: :in_sync} = BlockSync.synchronize("http://remote.test", @sync_url, ours)
    end

    test "removes nothing from a list that doesn't match its digest", ctx do
      remote_block!(ctx.bob, ctx.carol)
      stub_http(%{"/f/block_sync" => collection([], digest: String.duplicate("1", 64))})

      assert %{status: :synchronized_without_removals, removed: 0} =
               BlockSync.synchronize("http://remote.test", @sync_url)

      assert BlocksMutes.blocked?(ctx.bob.id, ctx.carol.id)
    end

    test "removes nothing when the list names a profile we can't place", ctx do
      remote_block!(ctx.bob, ctx.carol)
      pairs = [{aid(ctx.bob), AnglerWeb.Endpoint.url() <> "/users/nobody"}]
      stub_http(%{"/f/block_sync" => collection(pairs)})

      assert %{status: :synchronized_without_removals, removed: 0} =
               BlockSync.synchronize("http://remote.test", @sync_url)

      assert BlocksMutes.blocked?(ctx.bob.id, ctx.carol.id)
    end

    test "never applies blocks by another server's actors", ctx do
      pairs = [{aid(ctx.eve), aid(ctx.alice)}]
      stub_http(%{"/f/block_sync" => collection(pairs)})

      assert %{status: :synchronized_without_removals, added: 0} =
               BlockSync.synchronize("http://remote.test", @sync_url)

      refute BlocksMutes.blocked?(ctx.eve.id, ctx.alice.id)
    end

    test "a failed fetch backs off and an off-server URL is refused", ctx do
      stub_http(%{})

      assert %{status: :skipped} =
               BlockSync.synchronize("http://remote.test", "http://evil.test/x")

      assert :ok =
               perform_job(SyncWorker, %{
                 "authority" => "http://remote.test",
                 "url" => @sync_url,
                 "digest" => nil,
                 "periodic" => false
               })

      assert %DateTime{} = Repo.reload!(ctx.instance).block_sync_backoff_until
    end
  end

  test "the daily reconcile queues known endpoints, in turn", ctx do
    ctx.instance |> Ecto.Changeset.change(block_sync_url: @sync_url) |> Repo.update!()

    Repo.insert!(%Instance{
      domain: "liar.test",
      block_sync_url: "http://remote.test/f/block_sync"
    })

    assert :ok = perform_job(BlockSyncReconcile, %{"spread" => 0})

    assert [%{args: %{"authority" => "http://remote.test", "periodic" => true}}] =
             all_enqueued(worker: SyncWorker)

    assert %DateTime{} = Repo.reload!(ctx.instance).block_sync_queued_at
  end

  describe "GET /f/block_sync" do
    defp signed_get(conn, ctx, extra \\ []) do
      Repo.insert!(
        %HttpSignatureKey{
          key_id: "http://remote.test/users/bob#main-key",
          owner_url: ctx.bob.remote_url,
          public_key_pem: ctx.pub,
          fetched_at: DateTime.utc_now()
        },
        on_conflict: :nothing
      )

      {:ok, headers} =
        HTTPSignature.sign(
          :get,
          "/f/block_sync",
          "www.example.com",
          "",
          "http://remote.test/users/bob#main-key",
          ctx.priv,
          [{"Accept", "application/activity+json"}]
        )

      headers
      |> Enum.reject(fn {k, _} -> String.downcase(k) == "host" end)
      |> Kernel.++(extra)
      |> Enum.reduce(conn, fn {k, v}, c -> put_req_header(c, String.downcase(k), v) end)
      |> get("/f/block_sync")
    end

    test "lists the signer's server's blocks, with the digest as ETag", %{conn: conn} = ctx do
      {:ok, _} = BlocksMutes.block(ctx.alice, ctx.bob)
      {:ok, _} = BlocksMutes.block(ctx.carol, ctx.eve)

      resp = signed_get(conn, ctx)
      body = json_response(resp, 200)

      assert body["orderedItems"] == [
               %{"type" => "Block", "actor" => aid(ctx.alice), "object" => aid(ctx.bob)}
             ]

      assert body["blockSynchronizationDigest"] ==
               BlockSync.digest([{aid(ctx.alice), aid(ctx.bob)}])

      [etag] = get_resp_header(resp, "etag")
      assert etag == ~s("#{body["blockSynchronizationDigest"]}")

      assert build_conn() |> signed_get(ctx, [{"if-none-match", "W/" <> etag}]) |> response(304)
      assert build_conn() |> get("/f/block_sync") |> json_response(401)

      ctx.instance |> Ecto.Changeset.change(unlisted: true) |> Repo.update!()
      assert build_conn() |> signed_get(ctx) |> json_response(403)
    end

    test "the instance actor advertises it", %{conn: conn} do
      body = conn |> get("/i/actor") |> response(200) |> Jason.decode!()
      assert body["blockSynchronization"] == AnglerWeb.Endpoint.url() <> "/f/block_sync"
    end
  end
end
