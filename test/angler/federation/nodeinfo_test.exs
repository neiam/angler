defmodule Angler.Federation.NodeinfoTest do
  use Angler.DataCase, async: false

  alias Angler.Federation.Nodeinfo

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
      assert doc["software"]["version"] == "0.12.7"
      assert doc["protocols"] == ["activitypub"]
      # Angler's real identity + version live under metadata.software.
      assert doc["metadata"]["software"]["name"] == "Angler"
      assert doc["metadata"]["software"]["version"] == Nodeinfo.version()
      assert is_binary(doc["metadata"]["software"]["version"])
      assert doc["metadata"]["compatible"]["pixelfed"] == "0.12.7"

      usage = doc["usage"]
      assert is_map(usage["users"])
      assert is_integer(usage["users"]["total"])
      assert is_integer(usage["localPosts"])
    end

    test "stats default to zero when no node_stats row exists" do
      doc = Nodeinfo.document()

      assert doc["usage"]["users"]["total"] == 0
      assert doc["usage"]["users"]["activeMonth"] == 0
      assert doc["usage"]["localPosts"] == 0
    end
  end
end
