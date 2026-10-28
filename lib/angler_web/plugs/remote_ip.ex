defmodule AnglerWeb.Plugs.RemoteIp do
  @moduledoc """
  Sets `conn.remote_ip` to the real client address when the request came
  through a trusted reverse proxy (the cluster's Traefik ingress).

  Without this, `remote_ip` is the proxy's pod IP for every request, so
  anything keyed on it (the login throttle, token IPs) sees one client.

  Only a trusted peer's `X-Forwarded-For` is believed, and only its
  rightmost untrusted entry: each proxy appends the address it saw, so
  everything left of that is whatever the client chose to send. Entries
  are walked right to left across all header values in order; entries
  that don't parse are skipped. With an untrusted peer, or no usable
  entry, `remote_ip` is left alone.

  Trusted ranges are `Application.get_env(:angler, :trusted_proxies)`, a
  list of CIDR strings (`TRUSTED_PROXIES` in runtime.exs), defaulting to
  loopback, RFC 1918 and the IPv6 ULA range.
  """

  @behaviour Plug

  import Bitwise

  @default_trusted ~w(127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 ::1/128 fc00::/7)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    %{conn | remote_ip: from(conn.remote_ip, Plug.Conn.get_req_header(conn, "x-forwarded-for"))}
  end

  @doc """
  The client address behind a connected LiveView socket. The socket's peer
  is the ingress proxy, so this resolves it the same way `call/2` does.
  Only valid during `mount/3`, where connect info is available.
  """
  @spec from_socket(Phoenix.LiveView.Socket.t()) :: :inet.ip_address() | nil
  def from_socket(socket) do
    peer =
      case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
        %{address: address} -> address
        _ -> nil
      end

    forwarded_for =
      for {"x-forwarded-for", value} <-
            Phoenix.LiveView.get_connect_info(socket, :x_headers) || [],
          do: value

    from(peer, forwarded_for)
  end

  @doc """
  The client address for a request from `peer_ip` carrying the given
  `X-Forwarded-For` header values. Returns `peer_ip` unless it is a
  trusted proxy and the header names an untrusted address.
  """
  @spec from(:inet.ip_address() | nil, [String.t()]) :: :inet.ip_address() | nil
  def from(peer_ip, forwarded_for) do
    trusted = trusted_ranges()

    if peer_ip && trusted?(peer_ip, trusted) do
      forwarded_for
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.reverse()
      |> Enum.find_value(peer_ip, fn entry ->
        case parse(entry) do
          {:ok, ip} -> if trusted?(ip, trusted), do: nil, else: ip
          :error -> nil
        end
      end)
    else
      peer_ip
    end
  end

  defp parse(entry) do
    case :inet.parse_strict_address(String.to_charlist(String.trim(entry))) do
      {:ok, ip} -> {:ok, unmap(ip)}
      _ -> :error
    end
  end

  defp trusted?(ip, ranges) do
    ip = unmap(ip)
    Enum.any?(ranges, &in_cidr?(ip, &1))
  end

  defp trusted_ranges do
    :angler
    |> Application.get_env(:trusted_proxies, @default_trusted)
    |> Enum.flat_map(fn cidr ->
      case parse_cidr(cidr) do
        {:ok, range} -> [range]
        :error -> []
      end
    end)
  end

  defp parse_cidr(cidr) do
    {addr, prefix} =
      case String.split(String.trim(cidr), "/", parts: 2) do
        [addr, prefix] -> {addr, Integer.parse(prefix)}
        [addr] -> {addr, nil}
      end

    case :inet.parse_strict_address(String.to_charlist(addr)) do
      {:ok, net} -> with_prefix(net, prefix)
      _ -> :error
    end
  end

  defp with_prefix(net, prefix) do
    width = width(net)

    case prefix do
      nil -> {:ok, {net, width}}
      {p, ""} when p >= 0 and p <= width -> {:ok, {net, p}}
      _ -> :error
    end
  end

  # An IPv4 client on a dual-stack listener shows up as ::ffff:a.b.c.d.
  defp unmap({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}

  defp unmap(ip), do: ip

  defp in_cidr?(ip, {net, prefix}) when tuple_size(ip) == tuple_size(net) do
    shift = width(ip) - prefix
    to_int(ip) >>> shift == to_int(net) >>> shift
  end

  defp in_cidr?(_ip, _range), do: false

  defp width(ip) when tuple_size(ip) == 4, do: 32
  defp width(ip) when tuple_size(ip) == 8, do: 128

  defp bits_per_part(ip) when tuple_size(ip) == 4, do: 8
  defp bits_per_part(ip) when tuple_size(ip) == 8, do: 16

  defp to_int(ip) do
    bits = bits_per_part(ip)

    ip
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> (acc <<< bits) + part end)
  end
end
