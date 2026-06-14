defmodule AnglerWeb.Federation.NodeinfoControllerTest do
  use AnglerWeb.ConnCase, async: false

  test "GET /.well-known/nodeinfo links to the 2.0 schema", %{conn: conn} do
    conn = get(conn, "/.well-known/nodeinfo")

    body = json_response(conn, 200)
    assert [link] = body["links"]
    assert link["rel"] == "http://nodeinfo.diaspora.software/ns/schema/2.0"
    assert String.ends_with?(link["href"], "/api/nodeinfo/2.0.json")

    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "GET /api/nodeinfo/2.0.json returns the document", %{conn: conn} do
    conn = get(conn, ~p"/api/nodeinfo/2.0.json")

    body = json_response(conn, 200)
    assert body["version"] == "2.0"
    assert body["software"]["name"] == "angler"
    assert body["metadata"]["compatible"]["pixelfed"] == "0.12.5"
    assert body["protocols"] == ["activitypub"]
    assert is_map(body["usage"])
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end
end
