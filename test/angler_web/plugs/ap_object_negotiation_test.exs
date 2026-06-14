defmodule AnglerWeb.Plugs.APObjectNegotiationTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Profiles
  alias Angler.Statuses

  defp local!(username) do
    {:ok, p} = Profiles.create_profile(%{username: username})
    p
  end

  defp path_of(status) do
    URI.parse(status.uri).path
  end

  test "serves the AP Note object when AP is requested", %{conn: conn} do
    alice = local!("alice")
    {:ok, status} = Statuses.create_local(alice, %{"status" => "federate me"})

    conn =
      conn
      |> put_req_header("accept", "application/activity+json")
      |> get(path_of(status))

    assert response_content_type(conn, :json) =~ "activity+json"
    body = Jason.decode!(conn.resp_body)
    assert body["type"] == "Note"
    assert body["id"] == status.uri
    assert body["content"] =~ "federate me"
  end

  test "falls through to the HTML LiveView for browsers", %{conn: conn} do
    alice = local!("alice")
    {:ok, status} = Statuses.create_local(alice, %{"status" => "browser view"})

    conn = get(conn, path_of(status))

    assert html_response(conn, 200) =~ "browser view"
  end

  test "404 AP for an unknown id", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/activity+json")
      |> get("/p/ghost/999999999")

    assert conn.status == 404
    assert response_content_type(conn, :json) =~ "activity+json"
  end
end
