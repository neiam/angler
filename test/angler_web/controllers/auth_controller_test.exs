defmodule AnglerWeb.AuthControllerTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.{Accounts, Auth, OAuth}

  describe "POST /api/auth/app-code-verify" do
    setup do
      {:ok, code, _} = Auth.issue_code("alice@example.com")
      %{code: code}
    end

    test "returns success for a valid email + code", %{conn: conn, code: code} do
      conn =
        post(conn, ~p"/api/auth/app-code-verify", %{
          "email" => "alice@example.com",
          "verify_code" => code
        })

      assert json_response(conn, 200) == %{"status" => "success"}
    end

    test "returns error for wrong code", %{conn: conn} do
      conn =
        post(conn, ~p"/api/auth/app-code-verify", %{
          "email" => "alice@example.com",
          "verify_code" => "000000"
        })

      assert json_response(conn, 200) == %{"status" => "error"}
    end

    test "returns error if account already exists", %{conn: conn, code: code} do
      {:ok, _} =
        Accounts.register(%{
          username: "alice",
          email: "alice@example.com",
          password: "verysecret123"
        })

      conn =
        post(conn, ~p"/api/auth/app-code-verify", %{
          "email" => "alice@example.com",
          "verify_code" => code
        })

      body = json_response(conn, 200)
      assert body["status"] == "error"
      assert body["message"] =~ "already exists"
    end

    test "returns 422 when fields missing", %{conn: conn} do
      conn = post(conn, ~p"/api/auth/app-code-verify", %{"email" => "alice@example.com"})
      assert json_response(conn, 422)["status"] == "error"
    end

    test "is verify-only — does not consume the code", %{conn: conn, code: code} do
      _ =
        post(conn, ~p"/api/auth/app-code-verify", %{
          "email" => "alice@example.com",
          "verify_code" => code
        })

      conn2 =
        build_conn()
        |> post(~p"/api/auth/app-code-verify", %{
          "email" => "alice@example.com",
          "verify_code" => code
        })

      assert json_response(conn2, 200) == %{"status" => "success"}
    end
  end

  describe "POST /api/auth/onboarding" do
    setup do
      {:ok, code, _} = Auth.issue_code("alice@example.com")
      %{code: code}
    end

    test "creates user, profile, token; returns Pixelfed-shaped bundle", %{conn: conn, code: code} do
      conn =
        post(conn, ~p"/api/auth/onboarding", %{
          "email" => "alice@example.com",
          "verify_code" => code,
          "username" => "alice",
          "password" => "verysecret123",
          "name" => "Alice Example"
        })

      body = json_response(conn, 200)
      assert body["status"] == "success"
      assert body["token_type"] == "Bearer"
      assert is_binary(body["access_token"])
      assert is_binary(body["refresh_token"])
      assert body["user"]["username"] == "alice"
      assert is_binary(body["user"]["pid"])
      assert body["scope"] == ["read", "write", "follow", "push"]
      assert body["account"]["username"] == "alice"

      # The user is real
      assert %Angler.Accounts.User{} = Accounts.get_by_email("alice@example.com")

      # The bearer is usable
      assert {:ok, _} = OAuth.lookup_by_access(body["access_token"])

      # The AppRegister row was consumed
      assert is_nil(Auth.get_register("alice@example.com"))
    end

    test "rejects invalid verification code", %{conn: conn} do
      conn =
        post(conn, ~p"/api/auth/onboarding", %{
          "email" => "alice@example.com",
          "verify_code" => "000000",
          "username" => "alice",
          "password" => "verysecret123"
        })

      body = json_response(conn, 200)
      assert body["status"] == "error"
      assert body["message"] =~ "Invalid verification code"

      # No user created
      assert is_nil(Accounts.get_by_email("alice@example.com"))
    end

    test "rejects taken username", %{conn: conn, code: code} do
      {:ok, _} =
        Accounts.register(%{
          username: "alice",
          email: "other@example.com",
          password: "verysecret123"
        })

      conn =
        post(conn, ~p"/api/auth/onboarding", %{
          "email" => "alice@example.com",
          "verify_code" => code,
          "username" => "alice",
          "password" => "verysecret123"
        })

      body = json_response(conn, 422)
      assert body["status"] == "error"
      assert body["message"] =~ "Username is taken"
    end

    test "rejects restricted username", %{conn: conn, code: code} do
      conn =
        post(conn, ~p"/api/auth/onboarding", %{
          "email" => "alice@example.com",
          "verify_code" => code,
          "username" => "admin",
          "password" => "verysecret123"
        })

      body = json_response(conn, 422)
      assert body["status"] == "error"
      assert body["message"] =~ "Username"
    end

    test "returns 422 with explicit message when fields are missing", %{conn: conn} do
      conn = post(conn, ~p"/api/auth/onboarding", %{"email" => "alice@example.com"})
      body = json_response(conn, 422)
      assert body["status"] == "error"
      assert body["message"] =~ "Missing field"
    end
  end
end
