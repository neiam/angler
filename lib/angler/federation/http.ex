defmodule Angler.Federation.HTTP do
  @moduledoc """
  Guarded outbound HTTP fetcher for federation.

  Wraps `Req.get/2` with safety checks:
  * Scheme must be `https` (or `http` only when `Mix.env() == :test`)
  * Resolved host must not be in a private, loopback, link-local, CGNAT,
    multicast or reserved range — blocks SSRF into private infrastructure.
    Redirects are followed by hand so every hop is re-checked.
  * Host must not be in the banned-domain set
  * Response Content-Type must be in the allowlist (default: AP / JSON-LD)
  * Body capped at 1 MiB

  Federation peers can return surprises; the goal is to make this function
  the only place we ever issue server-to-server HTTP.
  """

  alias Angler.Federation.Bans

  @ap_content_types ~w(
    application/activity+json
    application/ld+json
    application/jrd+json
    application/json
  )

  @max_body_bytes 1_048_576
  @max_redirects 3

  @doc """
  Fetch a URL and return `{:ok, parsed_json}` on success.

  Options:
    * `:accept` — Accept header (default: `application/activity+json`)
    * `:content_types` — list of allowed response content types (default AP set)
    * `:max_bytes` — body cap (default 1 MiB)
    * `:signed_with` — `{key_id, private_key_pem}` to sign the GET request
  """
  @spec fetch(String.t(), keyword()) ::
          {:ok, map()}
          | {:error,
             :bad_scheme
             | :private_address
             | :banned_domain
             | :too_large
             | :bad_content_type
             | :bad_status
             | {:unavailable, pos_integer()}
             | :bad_json
             | term()}
  def fetch(url, opts \\ []) when is_binary(url) do
    accept = Keyword.get(opts, :accept, "application/activity+json")
    allowed = Keyword.get(opts, :content_types, @ap_content_types)
    max_bytes = Keyword.get(opts, :max_bytes, @max_body_bytes)

    with {:ok, resp} <- get_following_redirects(url, accept, opts[:signed_with], @max_redirects),
         :ok <- check_status(resp.status),
         :ok <- check_content_type(resp.headers, allowed),
         :ok <- check_size(resp.body, max_bytes),
         {:ok, json} <- Jason.decode(resp.body) do
      {:ok, json}
    end
  end

  @doc """
  POST to a remote inbox under the same URL guards as `fetch/2` (scheme,
  banned domain, private address). `req_opts` are passed to `Req.post/1`;
  redirects are never followed, since a redirected POST would be replayed as a
  GET against wherever the peer points it.
  """
  @spec deliver(keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def deliver(req_opts) when is_list(req_opts) do
    with {:ok, _uri} <- check_url(Keyword.fetch!(req_opts, :url)) do
      req_opts
      |> Keyword.merge(redirect: false)
      |> Keyword.merge(req_overrides())
      |> Req.post()
    end
  end

  @doc """
  Whether a `fetch/2` error looks temporary — timeouts, refused or reset
  connections, DNS failure, 408/429/5xx — as opposed to the remote saying
  no (404, 410, 401, a bad document) or our own guards refusing.
  """
  @spec transient_error?(term()) :: boolean()
  def transient_error?({:unavailable, _status}), do: true
  def transient_error?(:unresolvable), do: true
  def transient_error?(%Req.TransportError{}), do: true
  def transient_error?(%Mint.TransportError{}), do: true
  def transient_error?(_), do: false

  ## Internals

  defp get_following_redirects(url, accept, signed_with, hops_left) do
    with {:ok, uri} <- check_url(url),
         {:ok, resp} <-
           [
             url: url,
             headers: maybe_sign_get(uri, accept, signed_with),
             redirect: false,
             receive_timeout: 10_000,
             connect_options: [timeout: 5_000],
             decode_body: false
           ]
           |> Keyword.merge(req_overrides())
           |> Req.get() do
      case {resp.status, header(resp.headers, "location")} do
        {status, location} when status in [301, 302, 303, 307, 308] and location != nil ->
          if hops_left > 0 do
            next = uri |> URI.merge(location |> List.wrap() |> List.first()) |> URI.to_string()
            get_following_redirects(next, accept, signed_with, hops_left - 1)
          else
            {:error, :too_many_redirects}
          end

        _ ->
          {:ok, resp}
      end
    end
  end

  defp check_url(url) do
    with {:ok, %URI{scheme: scheme, host: host} = uri} <- parse_uri(url),
         :ok <- check_scheme(scheme),
         :ok <- check_banned(host),
         :ok <- check_resolved_host(host) do
      {:ok, uri}
    end
  end

  defp parse_uri(url) do
    case URI.parse(url) do
      %URI{scheme: s, host: h} = uri when is_binary(s) and is_binary(h) -> {:ok, uri}
      _ -> {:error, :bad_url}
    end
  end

  defp check_scheme("https"), do: :ok

  defp check_scheme("http") do
    if test_env?(), do: :ok, else: {:error, :bad_scheme}
  end

  defp check_scheme(_), do: {:error, :bad_scheme}

  defp check_banned(host) do
    if Bans.banned?(host), do: {:error, :banned_domain}, else: :ok
  end

  defp check_resolved_host(host) do
    cond do
      test_env?() -> :ok
      private_literal?(host) -> {:error, :private_address}
      true -> resolve_and_check(host)
    end
  end

  # If the host string itself is a private/loopback IP literal, reject without
  # DNS lookup. Helpful for tests too.
  defp private_literal?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, addr} -> private_ip?(addr)
      _ -> false
    end
  end

  defp resolve_and_check(host) do
    case :inet.getaddrs(String.to_charlist(host), :inet) do
      {:ok, addrs} ->
        if Enum.any?(addrs, &private_ip?/1), do: {:error, :private_address}, else: :ok

      _ ->
        # IPv4 lookup failed; try v6 before giving up.
        case :inet.getaddrs(String.to_charlist(host), :inet6) do
          {:ok, addrs} ->
            if Enum.any?(addrs, &private_ip?/1), do: {:error, :private_address}, else: :ok

          _ ->
            {:error, :unresolvable}
        end
    end
  end

  # IPv4 ranges that are never a federation peer: this-network, private,
  # CGNAT, loopback, link-local, IETF/doc/benchmark nets, multicast, reserved.
  @private_v4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 88, 99, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4}
  ]

  # IPv6: unspecified, loopback, discard, IETF/Teredo, documentation, ULA,
  # link-local, multicast. IPv4-mapped and NAT64 addresses are checked by
  # their embedded IPv4 address below.
  @private_v6 [
    {{0, 0, 0, 0, 0, 0, 0, 0}, 128},
    {{0, 0, 0, 0, 0, 0, 0, 1}, 128},
    {{0x100, 0, 0, 0, 0, 0, 0, 0}, 64},
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 23},
    {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32},
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
  ]

  @doc false
  # Public for tests.
  @spec private_ip?(:inet.ip_address()) :: boolean()
  def private_ip?({_, _, _, _} = ip), do: Enum.any?(@private_v4, &in_cidr?(ip, &1, 8))

  # ::ffff:a.b.c.d (IPv4-mapped) and 64:ff9b::a.b.c.d (NAT64)
  def private_ip?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: private_ip?(embedded_v4(hi, lo))
  def private_ip?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: private_ip?(embedded_v4(hi, lo))

  def private_ip?({_, _, _, _, _, _, _, _} = ip),
    do: Enum.any?(@private_v6, &in_cidr?(ip, &1, 16))

  def private_ip?(_), do: false

  defp embedded_v4(hi, lo), do: {div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)}

  defp in_cidr?(ip, {net, prefix}, bits_per_part) do
    width = tuple_size(ip) * bits_per_part
    shift = width - prefix

    Bitwise.bsr(to_int(ip, bits_per_part), shift) ==
      Bitwise.bsr(to_int(net, bits_per_part), shift)
  end

  defp to_int(tuple, bits_per_part) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> Bitwise.bsl(acc, bits_per_part) + part end)
  end

  defp check_status(s) when s in 200..299, do: :ok
  # 408/429/5xx mean "try again later"; the inbox retries first contact on
  # those (`transient_error?/1`), and drops the rest.
  defp check_status(s) when s in [408, 429] or s in 500..599, do: {:error, {:unavailable, s}}
  defp check_status(_), do: {:error, :bad_status}

  defp check_content_type(headers, allowed) do
    case header(headers, "content-type") do
      nil ->
        {:error, :bad_content_type}

      ct ->
        ct = ct |> List.wrap() |> List.first() |> to_string() |> String.downcase()
        base = ct |> String.split(";") |> List.first() |> String.trim()
        if base in allowed, do: :ok, else: {:error, :bad_content_type}
    end
  end

  defp check_size(body, max) when byte_size(body) <= max, do: :ok
  defp check_size(_, _), do: {:error, :too_large}

  defp header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} -> if String.downcase(to_string(k)) == name, do: v
    end)
  end

  defp header(%{} = headers, name) do
    case Map.get(headers, name) do
      nil -> Map.get(headers, String.to_atom(name))
      v -> v
    end
  end

  defp maybe_sign_get(_uri, accept, nil), do: [{"accept", accept}]

  defp maybe_sign_get(uri, accept, {key_id, private_key_pem}) do
    {:ok, headers} =
      Angler.Federation.HTTPSignature.sign(
        :get,
        request_target(uri),
        uri.host,
        "",
        key_id,
        private_key_pem,
        [{"Accept", accept}]
      )

    Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)
  end

  # `(request-target)` covers the query string too; signing the bare path
  # fails verification on authorized-fetch servers (upstream ed63be4d4).
  defp request_target(%URI{path: path, query: nil}), do: path || "/"
  defp request_target(%URI{path: path, query: q}), do: (path || "/") <> "?" <> q

  defp test_env? do
    # Avoids compile-time Mix dependency in production builds.
    Application.get_env(:angler, :env, :prod) == :test
  end

  # In test, callers can register a Req.Test stub via
  # `Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})`
  # so this module's outbound calls are intercepted without spinning up a
  # real listener.
  defp req_overrides do
    Application.get_env(:angler, :req_options, [])
  end
end
