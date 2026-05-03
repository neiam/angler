defmodule Angler.Federation.HTTP do
  @moduledoc """
  Guarded outbound HTTP fetcher for federation.

  Wraps `Req.get/2` with safety checks:
  * Scheme must be `https` (or `http` only when `Mix.env() == :test`)
  * Resolved host must not be in an RFC 1918 / loopback / link-local range —
    blocks SSRF into private infrastructure
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
             | :bad_json
             | term()}
  def fetch(url, opts \\ []) when is_binary(url) do
    accept = Keyword.get(opts, :accept, "application/activity+json")
    allowed = Keyword.get(opts, :content_types, @ap_content_types)
    max_bytes = Keyword.get(opts, :max_bytes, @max_body_bytes)

    with {:ok, %URI{scheme: scheme, host: host} = uri} <- parse_uri(url),
         :ok <- check_scheme(scheme),
         :ok <- check_banned(host),
         :ok <- check_resolved_host(host),
         req_headers <- maybe_sign_get(uri, accept, opts[:signed_with]),
         {:ok, resp} <-
           [
             url: url,
             headers: req_headers,
             max_redirects: 3,
             receive_timeout: 10_000,
             connect_options: [timeout: 5_000],
             decode_body: false
           ]
           |> Keyword.merge(req_overrides())
           |> Req.get(),
         :ok <- check_status(resp.status),
         :ok <- check_content_type(resp.headers, allowed),
         :ok <- check_size(resp.body, max_bytes),
         {:ok, json} <- Jason.decode(resp.body) do
      {:ok, json}
    end
  end

  ## Internals

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

  # IPv4 ranges
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({0, _, _, _}), do: true
  # IPv6 ranges
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip?({0xFC00, _, _, _, _, _, _, _}), do: true
  defp private_ip?({0xFD00, _, _, _, _, _, _, _}), do: true
  defp private_ip?({0xFE80, _, _, _, _, _, _, _}), do: true
  defp private_ip?(_), do: false

  defp check_status(s) when s in 200..299, do: :ok
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
        uri.path || "/",
        uri.host,
        "",
        key_id,
        private_key_pem,
        [{"Accept", accept}]
      )

    Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)
  end

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
