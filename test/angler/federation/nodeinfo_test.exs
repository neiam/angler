defmodule Angler.Federation.NodeinfoTest do
  use Angler.DataCase, async: false

  alias Angler.Accounts
  alias Angler.Federation.Nodeinfo
  alias Angler.Statuses

  describe "well_known/0" do
    test "links to the 2.0 schema document" do
      doc = Nodeinfo.well_known()

      [link] = doc["links"]
      assert link["rel"] == "http://nodeinfo.diaspora.software/ns/schema/2.0"
      assert String.ends_with?(link["href"], "/api/nodeinfo/2.0.json")
    end
  end

  describe "document/0" do
    test "shape" do
      doc = Nodeinfo.document()

      assert doc["version"] == "2.0"
      # Top-level software reports the Pixelfed API surface so the pixelfed-rn
      # app's nodeinfo preflight (name == "pixelfed" && version >= 0.12.3) passes.
      assert doc["software"]["name"] == "pixelfed"
      assert doc["software"]["version"] == "0.15.2"
      assert doc["protocols"] == ["activitypub"]
      # Angler's real identity + version live under metadata.software.
      assert doc["metadata"]["software"]["name"] == "Angler"
      assert doc["metadata"]["software"]["version"] == Nodeinfo.version()
      assert is_binary(doc["metadata"]["software"]["version"])
      assert doc["metadata"]["compatible"]["pixelfed"] == "0.15.2"

      usage = doc["usage"]
      assert is_map(usage["users"])
      assert is_integer(usage["users"]["total"])
      assert is_integer(usage["localPosts"])
    end

    test "usage is zero on an empty instance" do
      doc = Nodeinfo.document()

      assert doc["usage"]["users"]["total"] == 0
      assert doc["usage"]["users"]["activeMonth"] == 0
      assert doc["usage"]["localPosts"] == 0
    end

    test "usage counts local users, posts, replies and recent posters" do
      {:ok, %{profile: alice}} =
        Accounts.register(%{
          username: "alice",
          email: "alice@example.com",
          password: "passwordOK1"
        })

      {:ok, %{profile: bob}} =
        Accounts.register(%{username: "bob", email: "bob@example.com", password: "passwordOK1"})

      {:ok, post} = Statuses.create_local(alice, %{"status" => "hi", "visibility" => "public"})

      {:ok, _} =
        Statuses.create_local(alice, %{
          "status" => "reply",
          "visibility" => "public",
          "in_reply_to_id" => Integer.to_string(post.id)
        })

      # bob last posted eight months ago: counted in neither activity window
      {:ok, _} =
        Statuses.create_local(bob, %{"status" => "old", "visibility" => "public"},
          created_at: DateTime.add(DateTime.utc_now(), -240, :day)
        )

      Angler.Instance.clear_stats_cache()
      usage = Nodeinfo.document()["usage"]

      assert usage["users"]["total"] == 2
      assert usage["users"]["activeMonth"] == 1
      assert usage["users"]["activeHalfyear"] == 1
      assert usage["localPosts"] == 3
      assert usage["localComments"] == 1
    end
  end
end
