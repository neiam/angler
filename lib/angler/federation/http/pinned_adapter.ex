defmodule Angler.Federation.HTTP.PinnedAdapter do
  @moduledoc """
  Req adapter that connects to an IP address `Angler.Federation.HTTP` has
  already resolved and vetted, instead of letting Finch resolve the hostname
  again. Without this a DNS-rebinding peer could answer the guard's lookup
  with a public address and the connection's lookup with a private one.

  The pin is read from the request's private `:angler_pin`, a
  `{ip_address, hostname}` tuple. The hostname still drives the `Host`
  header, TLS SNI and certificate verification (Mint's `:hostname` option),
  so only the TCP destination changes.

  Each request opens and closes its own HTTP/1.1 connection: Finch pools by
  hostname, and a pool per pinned hostname would grow without bound across
  the fediverse. Response bodies stop being read past
  `:angler_max_body_bytes` (private, default 1 MiB), leaving a truncated body
  one byte over the cap for the caller's size check to reject.

  Honours Req's `:receive_timeout` (per read, as Finch) and
  `connect_options: [timeout:, transport_opts:]`; a whole exchange is also
  capped at 60 seconds.
  """

  @default_max_body 1_048_576
  @overall_timeout 60_000

  @doc false
  def run(%Req.Request{} = request) do
    {ip, hostname} = Req.Request.get_private(request, :angler_pin)
    max_body = Req.Request.get_private(request, :angler_max_body_bytes, @default_max_body)
    connect_options = Map.get(request.options, :connect_options, [])
    receive_timeout = Map.get(request.options, :receive_timeout, 15_000)

    transport_opts =
      Keyword.merge(
        [timeout: Keyword.get(connect_options, :timeout, 5_000)],
        Keyword.get(connect_options, :transport_opts, [])
      )

    mint_opts = [
      hostname: hostname,
      protocols: [:http1],
      mode: :passive,
      transport_opts: transport_opts
    ]

    uri = request.url

    case Mint.HTTP.connect(scheme(uri.scheme), ip, uri.port, mint_opts) do
      {:ok, conn} ->
        deadline = System.monotonic_time(:millisecond) + @overall_timeout

        try do
          exchange(conn, request, receive_timeout, deadline, max_body)
        after
          Mint.HTTP.close(conn)
        end

      {:error, error} ->
        {request, normalize_error(error)}
    end
  end

  defp exchange(conn, request, receive_timeout, deadline, max_body) do
    method = request.method |> to_string() |> String.upcase()
    headers = for {name, values} <- request.headers, value <- List.wrap(values), do: {name, value}

    case Mint.HTTP.request(conn, method, path(request.url), headers, request.body) do
      {:ok, conn, ref} ->
        acc = %{status: nil, headers: [], body: [], size: 0}

        case recv(conn, ref, acc, receive_timeout, deadline, max_body) do
          {:ok, acc} ->
            {request,
             Req.Response.new(
               status: acc.status,
               headers: acc.headers,
               body: IO.iodata_to_binary(acc.body)
             )}

          {:error, error} ->
            {request, normalize_error(error)}
        end

      {:error, _conn, error} ->
        {request, normalize_error(error)}
    end
  end

  defp recv(conn, ref, acc, receive_timeout, deadline, max_body) do
    timeout = min(receive_timeout, max(deadline - System.monotonic_time(:millisecond), 0))

    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, responses} ->
        case Enum.reduce_while(responses, {:cont, acc}, &collect(&1, &2, ref, max_body)) do
          {:done, acc} -> {:ok, acc}
          {:cont, acc} -> recv(conn, ref, acc, receive_timeout, deadline, max_body)
        end

      {:error, _conn, error, _responses} ->
        {:error, error}
    end
  end

  defp collect({:status, ref, status}, {_, acc}, ref, _max),
    do: {:cont, {:cont, %{acc | status: status}}}

  defp collect({:headers, ref, headers}, {_, acc}, ref, _max),
    do: {:cont, {:cont, %{acc | headers: acc.headers ++ headers}}}

  defp collect({:data, ref, data}, {_, acc}, ref, max) do
    size = acc.size + byte_size(data)
    acc = %{acc | body: [acc.body | data], size: size}

    if size > max do
      capped = binary_part(IO.iodata_to_binary(acc.body), 0, max + 1)
      {:halt, {:done, %{acc | body: capped}}}
    else
      {:cont, {:cont, acc}}
    end
  end

  defp collect({:done, ref}, {_, acc}, ref, _max), do: {:halt, {:done, acc}}
  defp collect(_other, state, _ref, _max), do: {:cont, state}

  defp path(%URI{path: path, query: query}) do
    path = if path in [nil, ""], do: "/", else: path
    if query, do: path <> "?" <> query, else: path
  end

  defp scheme("https"), do: :https
  defp scheme("http"), do: :http

  defp normalize_error(%Mint.TransportError{reason: reason}),
    do: %Req.TransportError{reason: reason}

  defp normalize_error(%Mint.HTTPError{reason: reason}),
    do: %Req.HTTPError{protocol: :http1, reason: reason}

  defp normalize_error(other), do: %Req.TransportError{reason: other}
end
