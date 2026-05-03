defmodule AnglerWeb.MastodonAPI.MediaControllerTest do
  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.Media
  alias Angler.OAuth

  @fixture Path.join([__DIR__, "..", "..", "..", "fixtures", "red.jpg"])

  setup do
    root =
      Path.join([System.tmp_dir!(), "angler-media-test-#{System.unique_integer([:positive])}"])

    File.mkdir_p!(root)
    Application.put_env(:angler, :media_root, root)

    on_exit(fn ->
      Application.delete_env(:angler, :media_root)
      File.rm_rf!(root)
    end)

    {:ok, %{user: user, profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{client: client} = OAuth.first_party_client!()
    {:ok, %{access: write}} = OAuth.issue_token(user, client, scopes: ["write"])
    {:ok, %{access: read}} = OAuth.issue_token(user, client, scopes: ["read"])

    %{alice: alice, write: write, read: read}
  end

  defp upload_fixture do
    src = Path.join(System.tmp_dir!(), "ang-mc-#{System.unique_integer([:positive])}.jpg")
    File.cp!(@fixture, src)
    %Plug.Upload{path: src, filename: "red.jpg", content_type: "image/jpeg"}
  end

  describe "POST /api/v1/media" do
    test "401 without bearer", ctx do
      conn = post(ctx.conn, ~p"/api/v1/media", %{"file" => upload_fixture()})
      assert json_response(conn, 401)
    end

    test "200 + Media JSON", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.write)
        |> post(~p"/api/v1/media", %{"file" => upload_fixture(), "description" => "a red square"})

      body = json_response(conn, 200)
      assert body["type"] == "image"
      assert body["description"] == "a red square"
      assert body["url"] =~ "/storage/m/v2/"
      assert is_binary(body["id"])
    end

    test "422 on text upload", ctx do
      txt = Path.join(System.tmp_dir!(), "ang-mc-#{System.unique_integer([:positive])}.txt")
      File.write!(txt, "nope")

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.write)
        |> post(~p"/api/v1/media", %{
          "file" => %Plug.Upload{path: txt, filename: "x.txt", content_type: "text/plain"}
        })

      assert json_response(conn, 422)
    end
  end

  describe "POST /api/v2/media" do
    test "202 + Media JSON", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.write)
        |> post(~p"/api/v2/media", %{"file" => upload_fixture()})

      body = json_response(conn, 202)
      assert body["type"] == "image"
    end
  end

  describe "GET /api/v1/media/:id" do
    test "206 while pending, 200 after worker drain", ctx do
      {:ok, asset} = Media.upload(ctx.alice, upload_fixture())

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.read)
        |> get(~p"/api/v1/media/#{Integer.to_string(asset.id)}")

      assert json_response(conn, 206)["id"] == Integer.to_string(asset.id)

      Oban.drain_queue(queue: :media)

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.read)
        |> get(~p"/api/v1/media/#{Integer.to_string(asset.id)}")

      body = json_response(conn, 200)
      assert body["meta"]["original"]["width"] == 64
    end
  end

  describe "PUT /api/v1/media/:id" do
    test "updates caption", ctx do
      {:ok, asset} = Media.upload(ctx.alice, upload_fixture())

      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.write)
        |> put(~p"/api/v1/media/#{Integer.to_string(asset.id)}", %{"description" => "updated"})

      assert json_response(conn, 200)["description"] == "updated"
    end
  end

  describe "GET /storage/*path serves bytes" do
    test "returns 200 image/jpeg", ctx do
      {:ok, asset} = Media.upload(ctx.alice, upload_fixture())

      path = "/storage/" <> asset.path_original
      conn = get(ctx.conn, path)

      assert response(conn, 200)
      [ct] = get_resp_header(conn, "content-type")
      assert ct =~ "image/jpeg"
    end
  end
end
