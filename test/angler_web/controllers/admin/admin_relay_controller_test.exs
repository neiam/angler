defmodule AnglerWeb.Admin.RelayControllerTest do
  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.Federation.Relays
  alias Angler.Federation.Workers.RelayDeliver
  alias Angler.OAuth
  alias Angler.Repo

  @actor "http://relay.test/actor"

  defp admin_bearer! do
    {:ok, %{user: user}} =
      Accounts.register(%{username: "mod", email: "mod@example.com", password: "verysecret123"})

    {:ok, user} = user |> Ecto.Changeset.change(is_admin: true) |> Repo.update()
    %{client: c} = OAuth.first_party_client!()

    {:ok, %{access: bearer}} =
      OAuth.issue_token(user, c, scopes: ["read", "write", "admin:read", "admin:write"])

    bearer
  end

  defp auth(conn, t), do: put_req_header(conn, "authorization", "Bearer " <> t)

  setup do
    # subscribe/1 fetches the relay actor to discover its inbox.
    Req.Test.stub(:angler_http, fn conn ->
      case conn.request_path do
        "/actor" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/activity+json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{
              "id" => @actor,
              "type" => "Application",
              "inbox" => "http://relay.test/inbox"
            })
          )

        _ ->
          Plug.Conn.send_resp(conn, 404, "not stubbed")
      end
    end)

    Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})
    on_exit(fn -> Application.delete_env(:angler, :req_options) end)
    Req.Test.set_req_test_to_shared(self())

    %{bearer: admin_bearer!()}
  end

  test "non-admin and anonymous are rejected", %{conn: conn} do
    {:ok, %{user: user}} =
      Accounts.register(%{username: "reg", email: "reg@example.com", password: "verysecret123"})

    %{client: c} = OAuth.first_party_client!()
    {:ok, %{access: bearer}} = OAuth.issue_token(user, c, scopes: ["read"])

    assert json_response(get(conn, ~p"/api/v1/admin/relays"), 401)
    assert json_response(auth(conn, bearer) |> get(~p"/api/v1/admin/relays"), 403)
  end

  test "create subscribes, lists, then deletes", ctx do
    create =
      ctx.conn |> auth(ctx.bearer) |> post(~p"/api/v1/admin/relays", %{"actor_url" => @actor})

    body = json_response(create, 200)
    assert body["actor"] == @actor
    assert body["inbox_url"] == "http://relay.test/inbox"
    assert body["state"] == "pending"
    assert_enqueued(worker: RelayDeliver, args: %{"verb" => "follow"})

    list = ctx.conn |> auth(ctx.bearer) |> get(~p"/api/v1/admin/relays") |> json_response(200)
    assert Enum.map(list, & &1["actor"]) == [@actor]

    del = ctx.conn |> auth(ctx.bearer) |> delete(~p"/api/v1/admin/relays/#{body["id"]}")
    assert json_response(del, 200) == %{}
    assert Relays.list() == []
  end

  test "create without actor_url → 422", ctx do
    conn = ctx.conn |> auth(ctx.bearer) |> post(~p"/api/v1/admin/relays", %{})
    assert json_response(conn, 422)["error"] =~ "actor_url"
  end

  test "enable/disable toggle state", ctx do
    {:ok, relay} = Relays.subscribe(@actor)

    disabled = ctx.conn |> auth(ctx.bearer) |> post(~p"/api/v1/admin/relays/#{relay.id}/disable")
    assert json_response(disabled, 200)["state"] == "idle"

    enabled = ctx.conn |> auth(ctx.bearer) |> post(~p"/api/v1/admin/relays/#{relay.id}/enable")
    assert json_response(enabled, 200)["state"] == "pending"
  end

  test "unknown id → 404", ctx do
    conn = ctx.conn |> auth(ctx.bearer) |> post(~p"/api/v1/admin/relays/999999/disable")
    assert json_response(conn, 404)
  end
end
