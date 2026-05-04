defmodule AnglerWeb.MastodonAPI.SettingsControllerTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.OAuth

  setup do
    {:ok, %{user: u, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: c} = OAuth.first_party_client!()
    {:ok, %{access: read}} = OAuth.issue_token(u, c, scopes: ["read"])
    {:ok, %{access: write}} = OAuth.issue_token(u, c, scopes: ["write"])

    %{alice: alice, user: u, read: read, write: write}
  end

  defp auth(conn, t), do: put_req_header(conn, "authorization", "Bearer " <> t)

  ## web/settings

  describe "web/settings" do
    test "GET returns [] when empty", ctx do
      assert [] =
               ctx.conn |> auth(ctx.read) |> get(~p"/api/v1.1/web/settings") |> json_response(200)
    end

    test "POST stores a whitelisted field; GET reads it back", ctx do
      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/web/settings", %{"field" => "enable_reblogs", "value" => true})
        |> json_response(200)

      body = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1.1/web/settings") |> json_response(200)
      assert body["enable_reblogs"] == true
    end

    test "POST with non-whitelisted field → 422", ctx do
      assert json_response(
               ctx.conn
               |> auth(ctx.write)
               |> post(~p"/api/v1.1/web/settings", %{"field" => "rogue", "value" => "x"}),
               422
             )
    end

    test "POST without field → 422", ctx do
      assert json_response(
               ctx.conn |> auth(ctx.write) |> post(~p"/api/v1.1/web/settings", %{}),
               422
             )
    end
  end

  ## app/settings

  describe "app/settings" do
    test "GET returns the canonical envelope with empty common when unset", ctx do
      body = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1.1/app/settings") |> json_response(200)
      assert body["id"] == Integer.to_string(ctx.alice.id)
      assert body["username"] == "alice"
      assert body["common"] == %{}
    end

    test "POST replaces common; GET reflects it", ctx do
      _ =
        ctx.conn
        |> auth(ctx.write)
        |> post(~p"/api/v1.1/app/settings", %{
          "common" => %{"theme" => "dark", "feed" => "chrono"}
        })
        |> json_response(200)

      body = ctx.conn |> auth(ctx.read) |> get(~p"/api/v1.1/app/settings") |> json_response(200)
      assert body["common"]["theme"] == "dark"
      assert body["common"]["feed"] == "chrono"
      assert body["updated_at"]
    end
  end

  ## compose/settings

  describe "compose/settings" do
    test "returns the server-side defaults map", ctx do
      body =
        ctx.conn |> auth(ctx.read) |> get(~p"/api/v1.1/compose/settings") |> json_response(200)

      assert is_list(body["allowed_media_types"])
      assert "image/jpeg" in body["allowed_media_types"]
      assert "video/mp4" in body["allowed_media_types"]
      assert body["max_caption_length"] > 0
      assert body["max_media_attachments"] > 0
      assert body["default_scope"] == "public"
    end

    test "default_scope reflects locked profile", ctx do
      ctx.alice
      |> Ecto.Changeset.change(is_private: true)
      |> Angler.Repo.update!()

      body =
        ctx.conn |> auth(ctx.read) |> get(~p"/api/v1.1/compose/settings") |> json_response(200)

      assert body["default_scope"] == "private"
    end
  end
end
