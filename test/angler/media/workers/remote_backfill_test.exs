defmodule Angler.Media.Workers.RemoteBackfillTest do
  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Media.Asset
  alias Angler.Media.Workers.RemoteBackfill
  alias Angler.Profiles
  alias Angler.Statuses.Status

  setup do
    {:ok, bob} =
      Profiles.create_profile(%{
        username: "bob",
        domain: "remote.test",
        remote_url: "http://remote.test/users/bob",
        inbox_url: "http://remote.test/users/bob/inbox",
        public_key_pem: "stub"
      })

    %{bob: bob}
  end

  defp remote_status!(profile, attrs) do
    Status.changeset(
      Map.merge(
        %{
          profile_id: profile.id,
          local: false,
          uri: "http://remote.test/notes/x",
          type: "photo",
          visibility: :public,
          scope: "public",
          caption: "hi",
          rendered: "<p>hi</p>"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  describe "candidate_ids/0" do
    test "selects remote, media-typed, asset-less statuses only", %{bob: bob} do
      want = remote_status!(bob, %{uri: "http://remote.test/notes/1", type: "photo"})
      # text post — excluded
      _text = remote_status!(bob, %{uri: "http://remote.test/notes/2", type: "text"})
      # already has an asset — excluded
      withmedia = remote_status!(bob, %{uri: "http://remote.test/notes/3", type: "video"})

      Repo.insert!(
        Asset.changeset(%{
          profile_id: bob.id,
          status_id: withmedia.id,
          media_type: "video/mp4",
          storage: "remote",
          status: "ready",
          remote_url: "http://remote.test/v.mp4"
        })
      )

      ids = RemoteBackfill.candidate_ids()
      assert want.id in ids
      refute withmedia.id in ids
      assert length(ids) == 1
    end
  end

  describe "perform/1" do
    setup do
      Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})
      on_exit(fn -> Application.delete_env(:angler, :req_options) end)
      Req.Test.set_req_test_to_shared(self())
      :ok
    end

    test "fetches the AP object and persists its attachments", %{bob: bob} do
      status = remote_status!(bob, %{uri: "http://remote.test/notes/77", type: "photo"})
      img = "http://remote.test/storage/77.jpg"

      note = %{
        "type" => "Note",
        "id" => status.uri,
        "attachment" => [
          %{"type" => "Document", "mediaType" => "image/jpeg", "url" => img, "name" => "alt"}
        ]
      }

      Req.Test.stub(:angler_http, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(200, Jason.encode!(note))
      end)

      assert :ok = perform_job(RemoteBackfill, %{"status_id" => status.id})

      assets = Repo.all(from(a in Asset, where: a.status_id == ^status.id))
      assert [asset] = assets
      assert asset.remote_url == img
      assert asset.storage == "remote"
    end

    test "no-ops when the status already has media (won't double-insert)", %{bob: bob} do
      status = remote_status!(bob, %{uri: "http://remote.test/notes/88", type: "photo"})

      Repo.insert!(
        Asset.changeset(%{
          profile_id: bob.id,
          status_id: status.id,
          media_type: "image/jpeg",
          storage: "remote",
          status: "ready",
          remote_url: "http://remote.test/already.jpg"
        })
      )

      # Stub raises if called — proves we short-circuit before fetching.
      Req.Test.stub(:angler_http, fn _ -> raise "should not fetch" end)

      assert :ok = perform_job(RemoteBackfill, %{"status_id" => status.id})
      assert Repo.aggregate(from(a in Asset, where: a.status_id == ^status.id), :count) == 1
    end
  end
end
