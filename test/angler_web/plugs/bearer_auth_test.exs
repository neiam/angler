defmodule AnglerWeb.Plugs.BearerAuthTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.OAuth
  alias Angler.Repo
  alias AnglerWeb.Plugs.BearerAuth

  setup do
    {:ok, %{user: user, profile: profile}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: client} = OAuth.first_party_client!()
    {:ok, %{access: access, token: token}} = OAuth.issue_token(user, client)

    %{user: user, profile: profile, client: client, access: access, token: token}
  end

  ## Plug-level (without going through the router)

  describe "init/1" do
    test "defaults to required, no scopes" do
      assert BearerAuth.init([]) == %{required: true, scopes: []}
    end

    test "optional flag" do
      assert BearerAuth.init(optional: true) == %{required: false, scopes: []}
    end

    test "scopes" do
      assert BearerAuth.init(scopes: ["read"]) == %{required: true, scopes: ["read"]}
    end
  end

  describe "call/2 (required)" do
    setup ctx do
      Map.put(ctx, :opts, BearerAuth.init([]))
    end

    test "no Authorization header → 401 + halts", %{conn: conn, opts: opts} do
      conn = BearerAuth.call(conn, opts)
      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "The access token is invalid"}
    end

    test "wrong scheme → 401", %{conn: conn, opts: opts} do
      conn =
        conn
        |> put_req_header("authorization", "Basic abcd")
        |> BearerAuth.call(opts)

      assert conn.halted
      assert conn.status == 401
    end

    test "unknown bearer → 401", %{conn: conn, opts: opts} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> BearerAuth.call(opts)

      assert conn.halted
      assert conn.status == 401
    end

    test "valid bearer → assigns current_scope", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.access)
        |> BearerAuth.call(ctx.opts)

      refute conn.halted
      scope = BearerAuth.current_scope(conn)
      assert scope.user.id == ctx.user.id
      assert scope.profile.id == ctx.profile.id
      assert scope.token.id == ctx.token.id
      assert scope.scopes == ctx.token.scopes
    end

    test "lowercase bearer prefix is also accepted", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "bearer " <> ctx.access)
        |> BearerAuth.call(ctx.opts)

      refute conn.halted
      assert BearerAuth.current_scope(conn).user.id == ctx.user.id
    end

    test "revoked token → 401", ctx do
      OAuth.revoke(ctx.token)

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.access)
        |> BearerAuth.call(ctx.opts)

      assert conn.halted
      assert conn.status == 401
    end

    test "expired token → 401", ctx do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      Ecto.Changeset.change(ctx.token, expires_at: past) |> Repo.update!()

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.access)
        |> BearerAuth.call(ctx.opts)

      assert conn.halted
      assert conn.status == 401
    end

    test "soft-deleted user → 401", ctx do
      Ecto.Changeset.change(ctx.user, status: "deleted") |> Repo.update!()

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.access)
        |> BearerAuth.call(ctx.opts)

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "call/2 (optional)" do
    setup do
      %{opts: BearerAuth.init(optional: true)}
    end

    test "no Authorization header → continues anonymous", %{conn: conn, opts: opts} do
      conn = BearerAuth.call(conn, opts)
      refute conn.halted
      assert is_nil(BearerAuth.current_scope(conn))
    end

    test "valid bearer → assigns current_scope", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.access)
        |> BearerAuth.call(ctx.opts)

      refute conn.halted
      assert BearerAuth.current_scope(conn).user.id == ctx.user.id
    end

    test "invalid bearer → continues anonymous (does NOT 401)", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer garbage")
        |> BearerAuth.call(ctx.opts)

      refute conn.halted
      assert is_nil(BearerAuth.current_scope(conn))
    end
  end

  describe "call/2 (scope check)" do
    test "valid bearer + sufficient scope → passes", ctx do
      opts = BearerAuth.init(scopes: ["read"])

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.access)
        |> BearerAuth.call(opts)

      refute conn.halted
      assert BearerAuth.current_scope(conn).user.id == ctx.user.id
    end

    test "valid bearer + parent scope satisfies child", ctx do
      opts = BearerAuth.init(scopes: ["read:accounts"])

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.access)
        |> BearerAuth.call(opts)

      refute conn.halted
    end

    test "valid bearer but scope not granted → 403", ctx do
      # Issue a token with only a narrow scope
      {:ok, %{access: narrow}} =
        OAuth.issue_token(ctx.user, ctx.client, scopes: ["read:accounts"])

      opts = BearerAuth.init(scopes: ["write"])

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> narrow)
        |> BearerAuth.call(opts)

      assert conn.halted
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] =~ "outside the authorized scopes"
    end

    test "missing bearer + scope check → 401 not 403", %{conn: conn} do
      opts = BearerAuth.init(scopes: ["write"])
      conn = BearerAuth.call(conn, opts)
      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "last_used_at debounce" do
    test "first authenticated request bumps last_used_at", ctx do
      assert is_nil(ctx.token.last_used_at)
      opts = BearerAuth.init([])

      ctx.conn
      |> put_req_header("authorization", "Bearer " <> ctx.access)
      |> BearerAuth.call(opts)

      reloaded = Repo.get!(Angler.OAuth.Token, ctx.token.id)
      refute is_nil(reloaded.last_used_at)
    end

    test "second request within 5min does NOT bump last_used_at", ctx do
      opts = BearerAuth.init([])

      ctx.conn
      |> put_req_header("authorization", "Bearer " <> ctx.access)
      |> BearerAuth.call(opts)

      first = Repo.get!(Angler.OAuth.Token, ctx.token.id).last_used_at
      Process.sleep(50)

      build_conn()
      |> put_req_header("authorization", "Bearer " <> ctx.access)
      |> BearerAuth.call(opts)

      second = Repo.get!(Angler.OAuth.Token, ctx.token.id).last_used_at
      assert first == second
    end

    test "request bumps if last_used_at is older than 5min", ctx do
      opts = BearerAuth.init([])
      stale = DateTime.add(DateTime.utc_now(), -600, :second)
      Ecto.Changeset.change(ctx.token, last_used_at: stale) |> Repo.update!()

      ctx.conn
      |> put_req_header("authorization", "Bearer " <> ctx.access)
      |> BearerAuth.call(opts)

      reloaded = Repo.get!(Angler.OAuth.Token, ctx.token.id)
      assert DateTime.diff(reloaded.last_used_at, stale, :second) >= 600
    end
  end
end
