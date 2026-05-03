defmodule AnglerWeb.Federation.InboxControllerTest do
  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  import Ecto.Query

  alias Angler.Federation.Workers.InboxValidator
  alias Angler.Profiles
  alias Angler.Repo

  setup do
    {:ok, profile} = Profiles.create_profile(%{username: "alice"})
    %{profile: profile}
  end

  defp signed_post(conn, path, payload) do
    body = Jason.encode!(payload)

    conn
    |> put_req_header("content-type", "application/activity+json")
    |> put_req_header("digest", "SHA-256=" <> Base.encode64(:crypto.hash(:sha256, body)))
    |> put_req_header("date", "Sun, 06 Nov 1994 08:49:37 GMT")
    |> put_req_header("signature", ~s(keyId="https://remote/x#main-key",signature="x"))
    |> Phoenix.ConnTest.dispatch(@endpoint, :post, path, body)
  end

  describe "POST /f/inbox (shared)" do
    test "202 + enqueues for valid-shaped payload", %{conn: conn} do
      payload = %{
        "id" => "https://remote.test/activities/1",
        "type" => "Create",
        "actor" => "https://remote.test/users/x"
      }

      conn = signed_post(conn, "/f/inbox", payload)
      assert response(conn, 202) == ""
      assert_enqueued(worker: InboxValidator)
    end

    test "400 on missing id/type", %{conn: conn} do
      conn = signed_post(conn, "/f/inbox", %{"type" => "Create"})
      assert response(conn, 400) == ""
      refute_enqueued(worker: InboxValidator)
    end

    test "400 on banned domain in id", %{conn: conn} do
      {:ok, instance} =
        %{domain: "spammy.example"}
        |> Angler.Federation.Instance.upsert_changeset()
        |> Repo.insert()

      Repo.update_all(
        from(i in Angler.Federation.Instance, where: i.id == ^instance.id),
        set: [banned: true]
      )

      Angler.Federation.Bans.bust()

      payload = %{
        "id" => "https://spammy.example/activities/1",
        "type" => "Create",
        "actor" => "https://spammy.example/users/x"
      }

      conn = signed_post(conn, "/f/inbox", payload)
      assert response(conn, 400) == ""
      refute_enqueued(worker: InboxValidator)
    end
  end

  describe "POST /users/:username/inbox" do
    test "202 for known local user", %{conn: conn, profile: _profile} do
      payload = %{
        "id" => "https://remote.test/activities/1",
        "type" => "Follow",
        "actor" => "https://remote.test/users/x",
        "object" => "http://localhost:4002/users/alice"
      }

      conn = signed_post(conn, "/users/alice/inbox", payload)
      assert response(conn, 202) == ""
      assert_enqueued(worker: InboxValidator)
    end

    test "404 for unknown username", %{conn: conn} do
      payload = %{
        "id" => "https://remote.test/activities/1",
        "type" => "Follow",
        "actor" => "https://remote.test/users/x",
        "object" => "http://localhost:4002/users/nobody"
      }

      conn = signed_post(conn, "/users/nobody/inbox", payload)
      assert response(conn, 404) == ""
      refute_enqueued(worker: InboxValidator)
    end
  end
end
