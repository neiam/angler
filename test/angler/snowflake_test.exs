defmodule Angler.SnowflakeTest do
  use ExUnit.Case, async: false

  alias Angler.Snowflake

  test "next/0 returns strictly monotonically increasing ids" do
    ids = Enum.map(1..1_000, fn _ -> Snowflake.next() end)
    assert ids == Enum.sort(ids)
    assert length(Enum.uniq(ids)) == 1_000
  end

  test "timestamp/1 round-trips the encoded millisecond" do
    before_ms = System.system_time(:millisecond)
    id = Snowflake.next()
    after_ms = System.system_time(:millisecond)

    ts = Snowflake.timestamp(id)
    assert ts >= before_ms
    assert ts <= after_ms
  end

  test "ids fit within 64 bits and are positive" do
    id = Snowflake.next()
    assert id > 0
    assert id < Bitwise.bsl(1, 63)
  end
end
