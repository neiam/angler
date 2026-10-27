defmodule AnglerWeb.Plugs.RemoteIpTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias AnglerWeb.Plugs.RemoteIp

  defp call(peer, forwarded_for) do
    conn = %{conn(:get, "/") | remote_ip: peer}

    forwarded_for
    |> List.wrap()
    |> Enum.reduce(conn, fn value, conn ->
      %{conn | req_headers: conn.req_headers ++ [{"x-forwarded-for", value}]}
    end)
    |> RemoteIp.call(RemoteIp.init([]))
    |> Map.fetch!(:remote_ip)
  end

  test "a trusted peer's chain gives the rightmost untrusted address" do
    assert call({10, 42, 0, 3}, "198.51.100.1, 203.0.113.9") == {203, 0, 113, 9}
  end

  test "an untrusted peer's header is ignored" do
    assert call({203, 0, 113, 9}, "1.2.3.4") == {203, 0, 113, 9}
  end

  test "trusted hops on the right are skipped" do
    assert call({127, 0, 0, 1}, "6.6.6.6, 198.51.100.1, 192.168.1.1, 10.0.0.2") ==
             {198, 51, 100, 1}
  end

  test "multiple header values are walked as one list, last value first" do
    assert call({10, 0, 0, 1}, ["198.51.100.1", "203.0.113.9, 172.16.0.4"]) ==
             {203, 0, 113, 9}
  end

  test "garbage entries are skipped" do
    assert call({10, 0, 0, 1}, "198.51.100.1, not-an-ip, , 999.1.1.1, unknown") ==
             {198, 51, 100, 1}
  end

  test "no usable entry leaves remote_ip alone" do
    assert call({10, 0, 0, 1}, "garbage, 10.0.0.9") == {10, 0, 0, 1}
    assert call({10, 0, 0, 1}, []) == {10, 0, 0, 1}
  end

  test "IPv6 peers and entries" do
    assert call({0, 0, 0, 0, 0, 0, 0, 1}, "2001:db8::1, fd00::5") ==
             {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}

    assert call({0xFD12, 0, 0, 0, 0, 0, 0, 1}, "2001:db8::2") ==
             {0x2001, 0xDB8, 0, 0, 0, 0, 0, 2}

    # Public v6 peer: not a proxy we trust.
    assert call({0x2001, 0xDB8, 0, 0, 0, 0, 0, 9}, "198.51.100.1") ==
             {0x2001, 0xDB8, 0, 0, 0, 0, 0, 9}
  end

  test "an IPv4-mapped IPv6 peer is matched against the IPv4 ranges" do
    assert call({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}, "198.51.100.1") ==
             {198, 51, 100, 1}
  end

  test "from/2 is what the plug applies" do
    assert RemoteIp.from({10, 0, 0, 1}, ["198.51.100.1"]) == {198, 51, 100, 1}
    assert RemoteIp.from(nil, ["198.51.100.1"]) == nil
  end

  test "put_req_header works too" do
    conn =
      conn(:get, "/")
      |> put_req_header("x-forwarded-for", "198.51.100.1")
      |> RemoteIp.call([])

    assert conn.remote_ip == {198, 51, 100, 1}
  end
end
