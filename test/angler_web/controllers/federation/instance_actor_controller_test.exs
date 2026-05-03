defmodule AnglerWeb.Federation.InstanceActorControllerTest do
  use AnglerWeb.ConnCase, async: false

  describe "GET /i/actor" do
    test "returns the actor document", %{conn: conn} do
      conn = get(conn, "/i/actor")

      assert get_resp_header(conn, "content-type") |> hd() =~ "application/activity+json"

      body = Jason.decode!(response(conn, 200))
      assert body["type"] == "Application"
      assert String.ends_with?(body["id"], "/i/actor")
      assert body["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
    end

    test "is byte-stable across calls (same key)", %{conn: conn} do
      a = get(conn, "/i/actor") |> response(200) |> Jason.decode!()
      b = build_conn() |> get("/i/actor") |> response(200) |> Jason.decode!()

      assert a == b
    end
  end

  describe "POST /i/actor/inbox" do
    test "accepts and discards", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/activity+json")
        |> post("/i/actor/inbox", Jason.encode!(%{"type" => "Like"}))

      assert response(conn, 202) == ""
    end
  end

  describe "GET /i/actor/outbox" do
    test "returns an empty OrderedCollection", %{conn: conn} do
      conn = get(conn, "/i/actor/outbox")

      assert get_resp_header(conn, "content-type") |> hd() =~ "application/activity+json"

      body = Jason.decode!(response(conn, 200))
      assert body["type"] == "OrderedCollection"
      assert body["totalItems"] == 0
    end
  end
end
