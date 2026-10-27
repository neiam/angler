defmodule Angler.Pagination.MastodonCursorTest do
  use ExUnit.Case, async: true

  alias Angler.Pagination.MastodonCursor

  describe "parse/3" do
    test "defaults" do
      cursor = MastodonCursor.parse(%{}, 20, 40)
      assert cursor.max_id == nil
      assert cursor.min_id == nil
      assert cursor.since_id == nil
      assert cursor.limit == 20
    end

    test "limit clamps to max" do
      assert MastodonCursor.parse(%{"limit" => "100"}, 20, 40).limit == 40
    end

    test "limit clamps to 1 minimum" do
      assert MastodonCursor.parse(%{"limit" => "0"}, 20, 40).limit == 1
      assert MastodonCursor.parse(%{"limit" => "-5"}, 20, 40).limit == 1
    end

    test "parses integer params" do
      cursor = MastodonCursor.parse(%{"max_id" => "100", "min_id" => "10"}, 20, 40)
      assert cursor.max_id == 100
      assert cursor.min_id == 10
    end

    test "ignores garbage values" do
      cursor = MastodonCursor.parse(%{"max_id" => "abc", "limit" => "xyz"}, 20, 40)
      assert cursor.max_id == nil
      assert cursor.limit == 20
    end

    test "treats non-positive cursor ids as unset" do
      # pixelfed-rn sends `max_id=0` as the initial infinite-query page param to
      # mean "from the start"; it must not become `where id < 0`.
      cursor =
        MastodonCursor.parse(%{"max_id" => "0", "min_id" => "0", "since_id" => "-1"}, 20, 40)

      assert cursor.max_id == nil
      assert cursor.min_id == nil
      assert cursor.since_id == nil
    end
  end

  describe "link_header/3" do
    test "nil for empty results" do
      assert MastodonCursor.link_header([], "https://x/api", :id) == nil
    end

    test "produces next + prev with cursor injected" do
      rows = [%{id: 30}, %{id: 20}, %{id: 10}]
      header = MastodonCursor.link_header(rows, "https://x/api/v1/timelines/home", :id)

      assert header =~ ~s(<https://x/api/v1/timelines/home?max_id=10>; rel="next")
      assert header =~ ~s(<https://x/api/v1/timelines/home?min_id=30>; rel="prev")
    end

    test "preserves non-cursor query params" do
      rows = [%{id: 30}, %{id: 10}]

      header =
        MastodonCursor.link_header(
          rows,
          "https://x/api/v1/timelines/public?local=true",
          :id
        )

      assert header =~ "local=true"
      assert header =~ "max_id=10"
    end

    test "strips prior cursor params from the supplied URL" do
      rows = [%{id: 30}, %{id: 10}]

      header =
        MastodonCursor.link_header(
          rows,
          "https://x/api/v1/timelines/home?max_id=999&min_id=500",
          :id
        )

      refute header =~ "max_id=999"
      refute header =~ "min_id=500"
      assert header =~ "max_id=10"
      assert header =~ "min_id=30"
    end
  end
end
