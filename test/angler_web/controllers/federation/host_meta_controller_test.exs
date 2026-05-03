defmodule AnglerWeb.Federation.HostMetaControllerTest do
  use AnglerWeb.ConnCase, async: true

  test "GET /.well-known/host-meta returns XRD pointing at webfinger", %{conn: conn} do
    conn = get(conn, "/.well-known/host-meta")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/xrd+xml"

    body = response(conn, 200)
    assert body =~ ~s(<?xml version="1.0" encoding="UTF-8"?>)
    assert body =~ ~s(<XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0">)
    assert body =~ ~s(rel="lrdd")
    assert body =~ "/.well-known/webfinger?resource={uri}"
  end
end
