defmodule AnglerWeb.MastodonAPI.ApiV1Dot1Test do
  @moduledoc "Pixelfed `/api/v1.1/...` namespace."

  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.Follows
  alias Angler.OAuth
  alias Angler.Profiles
  alias Angler.Reports.Report
  alias Angler.Statuses

  setup do
    {:ok, %{user: user, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: client} = OAuth.first_party_client!()
    {:ok, %{access: read}} = OAuth.issue_token(user, client, scopes: ["read"])
    {:ok, %{access: write}} = OAuth.issue_token(user, client, scopes: ["write"])

    %{alice: alice, user: user, read: read, write: write, client: client}
  end

  defp auth(conn, t), do: put_req_header(conn, "authorization", "Bearer " <> t)

  describe "bootstrap reads" do
    test "GET /accounts/login-activity is []", ctx do
      assert [] =
               ctx.conn
               |> auth(ctx.read)
               |> get(~p"/api/v1.1/accounts/login-activity")
               |> json_response(200)
    end

    test "GET /accounts/two-factor reports inactive by default", ctx do
      body =
        ctx.conn |> auth(ctx.read) |> get(~p"/api/v1.1/accounts/two-factor") |> json_response(200)

      assert body["active"] == false
      assert body["setup_at"] == nil
    end

    test "GET /accounts/emails-from-pixelfed is []", ctx do
      assert [] =
               ctx.conn
               |> auth(ctx.read)
               |> get(~p"/api/v1.1/accounts/emails-from-pixelfed")
               |> json_response(200)
    end

    test "GET /accounts/apps-and-applications lists the user's tokens", ctx do
      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.1/accounts/apps-and-applications")
        |> json_response(200)

      [first | _] = body
      assert is_binary(first["id"])
      assert is_binary(first["name"])
      assert is_list(first["scopes"])
      assert is_boolean(first["current_session"])
      # The token we used to authenticate IS in the list, but it's not necessarily
      # `current_session: true` because the issue_token+verify path bumps last_used.
      assert Enum.any?(body, & &1["current_session"])
    end

    test "GET /accounts/username/:username resolves to id", ctx do
      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.1/accounts/username/alice")
        |> json_response(200)

      assert body["id"] == Integer.to_string(ctx.alice.id)
    end

    test "GET /accounts/username/:username 404 for unknown", ctx do
      assert json_response(
               ctx.conn |> auth(ctx.read) |> get(~p"/api/v1.1/accounts/username/nope"),
               404
             )
    end

    test "GET /accounts/:id/posts returns the user's public posts", ctx do
      {:ok, _s} =
        Statuses.create_local(ctx.alice, %{"status" => "hello", "visibility" => "public"})

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.1/accounts/#{Integer.to_string(ctx.alice.id)}/posts")
        |> json_response(200)

      assert [post | _] = body
      assert post["content"] =~ "hello"
    end
  end

  describe "GET /accounts/mutuals/:id" do
    test "returns profiles both viewer and target follow with accepted edges", ctx do
      {:ok, %{profile: bob}} =
        Accounts.register(%{
          username: "bob",
          email: "bob@example.com",
          password: "passwordOK1"
        })

      {:ok, carol} = Profiles.create_profile(%{username: "carol"})

      {:ok, :accepted, _} = Follows.follow(ctx.alice, carol)
      {:ok, :accepted, _} = Follows.follow(bob, carol)

      body =
        ctx.conn
        |> auth(ctx.read)
        |> get(~p"/api/v1.1/accounts/mutuals/#{Integer.to_string(bob.id)}")
        |> json_response(200)

      assert [hit] = body
      assert hit["username"] == "carol"
    end
  end

  describe "DELETE /accounts/avatar" do
    test "clears avatar_path and returns the credential account", ctx do
      ctx.alice
      |> Ecto.Changeset.change(avatar_path: "https://x.test/img.jpg")
      |> Angler.Repo.update!()

      body =
        ctx.conn |> auth(ctx.write) |> delete(~p"/api/v1.1/accounts/avatar") |> json_response(200)

      assert body["avatar"] == ""
    end
  end

  describe "POST /accounts/change-password" do
    test "200 when current_password matches and new+confirm agree", ctx do
      body =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/accounts/change-password", %{
          "current_password" => "verysecret123",
          "new_password" => "evenmoresecret-123",
          "confirm_password" => "evenmoresecret-123"
        })
        |> json_response(200)

      assert body["message"] =~ "Password"

      # Old password no longer works.
      reloaded = Angler.Repo.get!(Angler.Accounts.User, ctx.user.id)
      refute Angler.Accounts.User.valid_password?(reloaded, "verysecret123")
      assert Angler.Accounts.User.valid_password?(reloaded, "evenmoresecret-123")
    end

    test "422 when current_password is wrong", ctx do
      body =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/accounts/change-password", %{
          "current_password" => "wrong",
          "new_password" => "evenmoresecret-123",
          "confirm_password" => "evenmoresecret-123"
        })
        |> json_response(422)

      assert body["errors"]["current_password"]
    end

    test "422 when confirm doesn't match", ctx do
      body =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/accounts/change-password", %{
          "current_password" => "verysecret123",
          "new_password" => "evenmoresecret-123",
          "confirm_password" => "different"
        })
        |> json_response(422)

      assert body["errors"]["confirm_password"]
    end
  end

  describe "POST /report" do
    test "creates a report for a remote user", ctx do
      {:ok, target} = Profiles.create_profile(%{username: "spammy"})

      body =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/report", %{
          "report_type" => "spam",
          "object_id" => Integer.to_string(target.id),
          "object_type" => "user"
        })
        |> json_response(200)

      assert body["msg"] =~ "Successfully"
      assert [%Report{type: "spam"}] = Angler.Repo.all(Report)
    end

    test "duplicate is rejected", ctx do
      {:ok, target} = Profiles.create_profile(%{username: "spammy"})

      params = %{
        "report_type" => "spam",
        "object_id" => Integer.to_string(target.id),
        "object_type" => "user"
      }

      _ = ctx.conn |> auth(ctx.write) |> post(~p"/api/v1.1/report", params)

      body =
        ctx.conn |> auth(ctx.write) |> post(~p"/api/v1.1/report", params) |> json_response(400)

      assert body["error_code"] == "ERROR_REPORT_DUPLICATE"
    end

    test "self-report is rejected", ctx do
      body =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/report", %{
          "report_type" => "spam",
          "object_id" => Integer.to_string(ctx.alice.id),
          "object_type" => "user"
        })
        |> json_response(400)

      assert body["error_code"] == "ERROR_NO_SELF_REPORTS"
    end

    test "invalid report_type rejected", ctx do
      {:ok, target} = Profiles.create_profile(%{username: "x"})

      body =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/report", %{
          "report_type" => "made_up",
          "object_id" => Integer.to_string(target.id),
          "object_type" => "user"
        })
        |> json_response(400)

      assert body["error_code"] == "ERROR_TYPE_INVALID"
    end
  end
end
