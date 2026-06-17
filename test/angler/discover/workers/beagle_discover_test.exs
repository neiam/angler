defmodule Angler.Discover.Workers.BeagleDiscoverTest do
  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Discover
  alias Angler.Discover.Workers.BeagleDiscover

  @author_url "http://remote.test/users/carol"
  @note_uri "http://remote.test/notes/beagle-1"

  setup do
    actor_doc = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => @author_url,
      "type" => "Person",
      "preferredUsername" => "carol",
      "inbox" => @author_url <> "/inbox",
      "publicKey" => %{
        "id" => @author_url <> "#main-key",
        "owner" => @author_url,
        "publicKeyPem" => "stub-key"
      }
    }

    note_doc = %{
      "type" => "Note",
      "id" => @note_uri,
      "url" => @note_uri,
      "attributedTo" => @author_url,
      "content" => "<p>beagle trending post</p>",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "sensitive" => false,
      "attachment" => [
        %{
          "type" => "Document",
          "mediaType" => "image/jpeg",
          "url" => "http://remote.test/media/1.jpg"
        }
      ]
    }

    beagle_doc = %{
      "statuses" => [
        %{"id" => @note_uri, "domain" => "remote.test", "score" => 99},
        # No usable id — must be dropped by the client.
        %{"domain" => "remote.test"}
      ]
    }

    Req.Test.stub(:angler_http, fn conn ->
      case conn.request_path do
        "/api/v1/discover" -> json(conn, beagle_doc, "application/json")
        "/users/carol" -> json(conn, actor_doc, "application/activity+json")
        "/notes/beagle-1" -> json(conn, note_doc, "application/activity+json")
        _ -> Plug.Conn.send_resp(conn, 404, "not stubbed")
      end
    end)

    Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})
    Application.put_env(:angler, Angler.Discover.Beagle, enabled: false)

    on_exit(fn ->
      Application.delete_env(:angler, :req_options)
      Application.put_env(:angler, Angler.Discover.Beagle, enabled: false)
    end)

    Req.Test.set_req_test_to_shared(self())
    :ok
  end

  test "no-op (ingests nothing) when disabled" do
    assert :ok = perform_job(BeagleDiscover, %{})
    assert Discover.network_trending(nil) == []
  end

  test "when enabled, mirrors Beagle posts so they surface in network_trending" do
    Application.put_env(:angler, Angler.Discover.Beagle, enabled: true)

    assert :ok = perform_job(BeagleDiscover, %{})

    posts = Discover.network_trending(nil)
    assert @note_uri in Enum.map(posts, & &1.uri)
    # Mirrored as a remote photo post.
    [post] = posts
    assert post.local == false
    assert post.type == "photo"
  end

  test "ingest is idempotent across runs" do
    Application.put_env(:angler, Angler.Discover.Beagle, enabled: true)

    assert :ok = perform_job(BeagleDiscover, %{})
    assert :ok = perform_job(BeagleDiscover, %{})

    assert length(Discover.network_trending(nil)) == 1
  end

  defp json(conn, body, content_type) do
    conn
    |> Plug.Conn.put_resp_content_type(content_type)
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
