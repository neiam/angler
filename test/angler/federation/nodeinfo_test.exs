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
      assert doc["software"]["name"] == "angler"
      assert doc["software"]["version"] == Nodeinfo.version()
      assert is_binary(doc["software"]["version"])
      assert doc["protocols"] == ["activitypub"]
      # Pixelfed compatibility is advertised in metadata, not as the software name.
      assert doc["metadata"]["compatible"]["pixelfed"] == "0.12.5"

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
