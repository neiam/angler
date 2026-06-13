defmodule AnglerWeb.PageControllerTest do
  use AnglerWeb.ConnCase

  # `/` is now served by AnglerWeb.IndexLive (the public web frontend). The
  # dead render still returns 200 with the landing content; see
  # AnglerWeb.WebFrontendTest for the connected LiveView coverage.
  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Known Network"
  end
end
