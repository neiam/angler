defmodule AnglerWeb.MastodonAPI.TimelineControllerTest do
  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.Follows.Follower
  alias Angler.OAuth
  alias Angler.Profiles
  alias Angler.Repo
  alias Angler.Statuses
  alias Angler.Timelines.Workers.FeedInsert

  setup do
    {:ok, %{user: user, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: client} = OAuth.first_party_client!()
    {:ok, %{access: bearer}} = OAuth.issue_token(user, client)

    {:ok, bob} =
      Profiles.create_profile(%{
        username: "bob",
        domain: "remote.test",
        remote_url: "http://remote.test/users/bob",
        inbox_url: "http://remote.test/users/bob/inbox",
        public_key_pem: "stub"
      })

    %{user: user, alice: alice, bob: bob, bearer: bearer}
  end

  defp insert_status!(profile, attrs \\ %{}) do
    base = %{
      profile_id: profile.id,
      visibility: :public,
      caption: "hi",
      rendered: "<p>hi</p>",
      type: "text",
      local: is_nil(profile.domain),
      uri:
        if(is_nil(profile.domain),
          do: nil,
          else: "http://remote.test/notes/#{System.unique_integer([:positive])}"
        )
    }

    {:ok, status} = Statuses.create_remote(Map.merge(base, attrs))
    status
  end

  describe "GET /api/v1/timelines/home" do
    test "401 without bearer", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/timelines/home")
      assert json_response(conn, 401)
    end

    test "200 + empty for a user with no follows", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.bearer)
        |> get(~p"/api/v1/timelines/home")

      assert json_response(conn, 200) == []
    end

    test "200 with statuses after follow + fan-out", ctx do
      Repo.insert!(
        Follower.changeset(%{
          profile_id: ctx.bob.id,
          following_id: ctx.alice.id,
          accepted_at: DateTime.utc_now()
        })
      )

      s1 = insert_status!(ctx.bob)
      s2 = insert_status!(ctx.bob)
      Enum.each([s1, s2], &FeedInsert.enqueue(&1.id))
      Oban.drain_queue(queue: :feed)

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.bearer)
        |> get(~p"/api/v1/timelines/home")

      body = json_response(conn, 200)
      assert length(body) == 2
      ids = Enum.map(body, & &1["id"])
      assert ids == [Integer.to_string(s2.id), Integer.to_string(s1.id)]
      assert hd(body)["account"]["acct"] == "bob@remote.test"
    end

    test "Link header present when results exist", ctx do
      Repo.insert!(
        Follower.changeset(%{
          profile_id: ctx.bob.id,
          following_id: ctx.alice.id,
          accepted_at: DateTime.utc_now()
        })
      )

      s = insert_status!(ctx.bob)
      FeedInsert.enqueue(s.id)
      Oban.drain_queue(queue: :feed)

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.bearer)
        |> get(~p"/api/v1/timelines/home")

      [link] = get_resp_header(conn, "link")
      assert link =~ ~s(rel="next")
      assert link =~ ~s(rel="prev")
    end
  end

  describe "GET /api/v1/timelines/public" do
    test "returns public statuses across profiles", ctx do
      s_local = insert_status!(ctx.alice)
      s_remote = insert_status!(ctx.bob)

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.bearer)
        |> get(~p"/api/v1/timelines/public")

      body = json_response(conn, 200)
      ids = Enum.map(body, & &1["id"])
      assert Integer.to_string(s_local.id) in ids
      assert Integer.to_string(s_remote.id) in ids
    end

    test "?local=true filters", ctx do
      _local = insert_status!(ctx.alice)
      _remote = insert_status!(ctx.bob)

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.bearer)
        |> get(~p"/api/v1/timelines/public?local=true")

      body = json_response(conn, 200)
      assert length(body) == 1
      assert hd(body)["account"]["acct"] == "alice"
    end
  end

  describe "GET /api/v1/timelines/tag/:hashtag" do
    test "returns matching statuses", ctx do
      tag = Angler.Hashtags.ensure!("photography")
      s = insert_status!(ctx.alice)

      Repo.insert!(%Angler.Statuses.StatusHashtag{
        status_id: s.id,
        hashtag_id: tag.id,
        profile_id: ctx.alice.id,
        status_visibility: "public",
        inserted_at: DateTime.utc_now()
      })

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.bearer)
        |> get(~p"/api/v1/timelines/tag/photography")

      body = json_response(conn, 200)
      assert [%{"id" => sid}] = body
      assert sid == Integer.to_string(s.id)
    end

    test "case-insensitive", ctx do
      tag = Angler.Hashtags.ensure!("photography")
      s = insert_status!(ctx.alice)

      Repo.insert!(%Angler.Statuses.StatusHashtag{
        status_id: s.id,
        hashtag_id: tag.id,
        profile_id: ctx.alice.id,
        status_visibility: "public",
        inserted_at: DateTime.utc_now()
      })

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.bearer)
        |> get(~p"/api/v1/timelines/tag/PHOTOGRAPHY")

      body = json_response(conn, 200)
      assert length(body) == 1
    end

    test "returns empty for unknown tag", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.bearer)
        |> get(~p"/api/v1/timelines/tag/nonexistent")

      assert json_response(conn, 200) == []
    end
  end
end
