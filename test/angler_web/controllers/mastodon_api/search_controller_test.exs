defmodule AnglerWeb.MastodonAPI.SearchControllerTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.Hashtags
  alias Angler.OAuth
  alias Angler.Profiles
  alias Angler.Statuses

  setup do
    {:ok, %{user: user}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: client} = OAuth.first_party_client!()
    {:ok, %{access: read}} = OAuth.issue_token(user, client, scopes: ["read"])

    {:ok, alpaca} = Profiles.create_profile(%{username: "alpaca"})
    {:ok, _} = Profiles.create_profile(%{username: "bob"})

    {:ok, _alpha_status} =
      Statuses.create_remote(%{
        profile_id: alpaca.id,
        visibility: :public,
        caption: "alpacas are friendly creatures",
        rendered: "<p>alpacas are friendly creatures</p>",
        type: "text",
        local: false,
        uri: "http://remote.test/notes/alp"
      })

    Hashtags.ensure!("alpacas")
    Hashtags.ensure!("photography")

    %{read: read}
  end

  defp auth(conn, t), do: put_req_header(conn, "authorization", "Bearer " <> t)

  test "GET /api/v2/search returns combined buckets", ctx do
    conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v2/search?q=alp")
    body = json_response(conn, 200)

    assert is_list(body["accounts"])
    assert is_list(body["statuses"])
    assert is_list(body["hashtags"])

    assert Enum.any?(body["accounts"], &(&1["username"] == "alpaca"))
    assert Enum.any?(body["hashtags"], &(&1["name"] == "alpacas"))
    assert Enum.any?(body["statuses"], &(&1["content"] =~ "alpacas"))
  end

  test "type=accounts returns only accounts", ctx do
    conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v2/search?q=alp&type=accounts")
    body = json_response(conn, 200)
    assert body["statuses"] == []
    assert body["hashtags"] == []
    refute body["accounts"] == []
  end

  test "empty q returns empty buckets", ctx do
    conn = auth(ctx.conn, ctx.read) |> get(~p"/api/v2/search?q=")
    body = json_response(conn, 200)
    assert body["accounts"] == []
    assert body["statuses"] == []
    assert body["hashtags"] == []
  end

  test "401 without bearer", ctx do
    conn = get(ctx.conn, ~p"/api/v2/search?q=alp")
    assert json_response(conn, 401)
  end
end
