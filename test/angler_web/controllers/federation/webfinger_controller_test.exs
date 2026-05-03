defmodule AnglerWeb.Federation.WebfingerControllerTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Profiles

  describe "GET /.well-known/webfinger" do
    test "returns 400 with empty body when resource is missing", %{conn: conn} do
      conn = get(conn, "/.well-known/webfinger")
      assert response(conn, 400) == ""
    end

    test "returns 400 for foreign domain", %{conn: conn} do
      conn = get(conn, "/.well-known/webfinger?resource=acct:alice@otherhost")
      assert response(conn, 400) == ""
    end

    test "returns 400 for unknown local user", %{conn: conn} do
      conn = get(conn, "/.well-known/webfinger?resource=acct:nobody@localhost")
      assert response(conn, 400) == ""
    end

    test "returns JRD for known local user", %{conn: conn} do
      {:ok, _} = Profiles.create_profile(%{username: "alice"})

      conn = get(conn, "/.well-known/webfinger?resource=acct:alice@localhost")

      assert get_resp_header(conn, "content-type") |> hd() =~ "application/jrd+json"
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]

      body = Jason.decode!(response(conn, 200))
      assert body["subject"] == "acct:alice@localhost"

      self = Enum.find(body["links"], &(&1["rel"] == "self"))
      assert self["type"] == "application/activity+json"
      assert String.ends_with?(self["href"], "/users/alice")
    end

    test "returns JRD for the instance actor", %{conn: conn} do
      conn = get(conn, "/.well-known/webfinger?resource=acct:localhost@localhost")

      body = Jason.decode!(response(conn, 200))
      assert body["subject"] == "acct:localhost@localhost"

      self = Enum.find(body["links"], &(&1["rel"] == "self"))
      assert String.ends_with?(self["href"], "/i/actor")
    end

    test "accepts the https URL form", %{conn: conn} do
      {:ok, _} = Profiles.create_profile(%{username: "alice"})

      conn = get(conn, "/.well-known/webfinger?resource=https://localhost/users/alice")
      body = Jason.decode!(response(conn, 200))

      assert body["subject"] == "acct:alice@localhost"
    end
  end
end
