defmodule AnglerWeb.HealthControllerTest do
  use AnglerWeb.ConnCase, async: false

  test "GET /api/service/health-check (liveness)", %{conn: conn} do
    conn = get(conn, ~p"/api/service/health-check")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "GET /api/service/health-check?level=ready (readiness)", %{conn: conn} do
    conn = get(conn, ~p"/api/service/health-check?level=ready")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
