defmodule Angler.Federation.HTTPSignature do
  @moduledoc """
  HTTP signatures (draft-cavage-http-signatures-12) — sign + verify.

  We support exactly the algorithm Mastodon and Pixelfed use today:
  `rsa-sha256` over `(request-target) host date digest [content-type]`. Any
  algorithm string we receive is treated as `rsa-sha256` since the spec
  explicitly deprecated putting algorithm in the wire format. Body integrity
  comes from the `Digest: SHA-256=...` header, which we always require for
  POSTs.

  This is a small, focused module — under 200 LOC — because the spec is small.
  See plans/federation/queues/inbox_validator.md for the surrounding context.
  """

  require Logger

  @doc """
  Verify an inbound signature.

  Args:
    * `method` — `:post` or `:get` (lowercased atom)
    * `path`   — the request path including query string, e.g. `"/users/x/inbox"`
    * `headers` — list of `{name_lower, value}` tuples (Plug normalizes already)
    * `raw_body` — the byte-exact request body
    * `key_resolver` — fn key_id -> {:ok, public_key_pem} | :error

  Returns `:ok | {:error, reason}`.
  """
  @spec verify(
          atom(),
          String.t(),
          [{String.t(), String.t()}],
          binary(),
          (String.t() -> {:ok, String.t()} | :error)
        ) ::
          :ok | {:error, atom()}
  def verify(method, path, headers, raw_body, key_resolver)
      when is_atom(method) and is_binary(path) and is_list(headers) and is_binary(raw_body) and
             is_function(key_resolver, 1) do
    with {:ok, sig_header} <- header(headers, "signature") |> ok_or(:missing_signature),
         {:ok, parts} <- parse_signature_header(sig_header),
         {:ok, key_id} <- Map.fetch(parts, "keyId") |> ok_or(:missing_key_id),
         {:ok, header_list_str} <- Map.fetch(parts, "headers") |> ok_or(:missing_headers),
         {:ok, sig_b64} <- Map.fetch(parts, "signature") |> ok_or(:missing_signature),
         {:ok, sig} <- Base.decode64(sig_b64) |> ok_or(:bad_signature_base64),
         header_names = String.split(header_list_str, " "),
         :ok <- ensure_required_headers(header_names),
         {:ok, signing_string} <- build_signing_string(method, path, headers, header_names),
         :ok <- verify_digest(headers, raw_body),
         :ok <- verify_date_skew(headers),
         {:ok, public_pem} <- key_resolver.(key_id) |> ok_or(:key_not_found),
         {:ok, public_key} <- decode_public_pem(public_pem) do
      if :public_key.verify(signing_string, :sha256, sig, public_key) do
        :ok
      else
        {:error, :bad_signature}
      end
    end
  end

  @doc """
  Sign an outbound request.

  Args:
    * `method`, `path`, `host` — the request line
    * `body` — byte-exact body (will be sha256+base64 for the Digest header)
    * `key_id`, `private_key_pem` — the signing identity
    * `extra_headers` — anything the caller wants to add, e.g. `Content-Type`.
      Returned to the caller along with the signature.

  Returns `{:ok, headers}` where `headers` is the full list to send including
  `Date`, `Host`, `Digest`, `Signature`, and any extras.
  """
  @spec sign(
          atom(),
          String.t(),
          String.t(),
          binary(),
          String.t(),
          String.t(),
          [{String.t(), String.t()}]
        ) :: {:ok, [{String.t(), String.t()}]}
  def sign(method, path, host, body, key_id, private_key_pem, extra_headers \\ []) do
    method_str = method |> Atom.to_string() |> String.downcase()
    date = http_date(DateTime.utc_now())
    digest = "SHA-256=" <> Base.encode64(:crypto.hash(:sha256, body))

    base_headers = [
      {"host", host},
      {"date", date},
      {"digest", digest}
    ]

    extras_lower = Enum.map(extra_headers, fn {k, v} -> {String.downcase(k), v} end)
    all = base_headers ++ extras_lower

    header_names = ["(request-target)" | Enum.map(all, fn {k, _} -> k end)]

    signing_string =
      [
        "(request-target): #{method_str} #{path}"
        | Enum.map(all, fn {k, v} -> "#{k}: #{v}" end)
      ]
      |> Enum.join("\n")

    {:ok, private_key} = decode_private_pem(private_key_pem)
    sig = :public_key.sign(signing_string, :sha256, private_key)
    sig_b64 = Base.encode64(sig)

    signature_header =
      ~s(keyId="#{key_id}",algorithm="rsa-sha256",headers="#{Enum.join(header_names, " ")}",signature="#{sig_b64}")

    {:ok,
     [
       {"Host", host},
       {"Date", date},
       {"Digest", digest},
       {"Signature", signature_header}
       | extra_headers
     ]}
  end

  ## Internals — header parsing

  @doc false
  # Public for the test suite; not part of the API surface.
  def parse_signature_header(value) when is_binary(value) do
    parts =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reduce(%{}, fn pair, acc ->
        case String.split(pair, "=", parts: 2) do
          [k, v] ->
            v_unquoted = v |> String.trim() |> String.trim("\"")
            Map.put(acc, k |> String.trim() |> String.trim("\""), v_unquoted)

          _ ->
            acc
        end
      end)

    if map_size(parts) > 0, do: {:ok, parts}, else: {:error, :bad_signature_header}
  end

  defp header(headers, name) do
    name = String.downcase(name)
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end

  defp ok_or(nil, reason), do: {:error, reason}
  defp ok_or(:error, reason), do: {:error, reason}
  defp ok_or({:ok, _} = ok, _), do: ok
  defp ok_or(value, _), do: {:ok, value}

  ## Internals — signing string construction

  defp ensure_required_headers(names) do
    cond do
      "(request-target)" not in names -> {:error, :missing_request_target}
      "host" not in names -> {:error, :missing_host}
      "date" not in names -> {:error, :missing_date}
      "digest" not in names -> {:error, :missing_digest}
      true -> :ok
    end
  end

  defp build_signing_string(method, path, headers, header_names) do
    method_str = method |> Atom.to_string() |> String.downcase()

    lines =
      Enum.map(header_names, fn
        "(request-target)" ->
          {:ok, "(request-target): #{method_str} #{path}"}

        name ->
          case header(headers, name) do
            nil -> {:error, {:missing_header, name}}
            value -> {:ok, "#{name}: #{String.trim(value)}"}
          end
      end)

    case Enum.find(lines, &match?({:error, _}, &1)) do
      nil ->
        {:ok, lines |> Enum.map(fn {:ok, l} -> l end) |> Enum.join("\n")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Internals — guards

  defp verify_digest(headers, raw_body) do
    case header(headers, "digest") do
      nil ->
        {:error, :missing_digest_header}

      value ->
        case String.split(value, "=", parts: 2) do
          ["SHA-256", encoded] ->
            expected = :crypto.hash(:sha256, raw_body)

            case Base.decode64(encoded) do
              {:ok, ^expected} -> :ok
              {:ok, _} -> {:error, :bad_digest}
              :error -> {:error, :bad_digest_base64}
            end

          _ ->
            {:error, :unsupported_digest_algorithm}
        end
    end
  end

  # 12-hour window matches Mastodon. Anything older is replay or clock-skew.
  @date_skew_seconds 12 * 60 * 60

  defp verify_date_skew(headers) do
    case header(headers, "date") do
      nil ->
        {:error, :missing_date}

      date_str ->
        case parse_http_date(date_str) do
          {:ok, dt} ->
            diff = abs(DateTime.diff(DateTime.utc_now(), dt, :second))
            if diff <= @date_skew_seconds, do: :ok, else: {:error, :date_skew}

          :error ->
            {:error, :unparseable_date}
        end
    end
  end

  ## Internals — key + date encoding

  defp decode_public_pem(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] ->
        try do
          {:ok, :public_key.pem_entry_decode(entry)}
        rescue
          _ -> {:error, :bad_public_key}
        end

      _ ->
        {:error, :bad_public_key_pem}
    end
  end

  defp decode_private_pem(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] ->
        try do
          {:ok, :public_key.pem_entry_decode(entry)}
        rescue
          _ -> {:error, :bad_private_key}
        end

      _ ->
        {:error, :bad_private_key_pem}
    end
  end

  @doc "RFC 7231 IMF-fixdate (e.g. \"Sun, 06 Nov 1994 08:49:37 GMT\")."
  def http_date(%DateTime{} = dt) do
    dt
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  defp parse_http_date(str) do
    # Parse "Sun, 06 Nov 1994 08:49:37 GMT" via Calendar.strftime is read-only;
    # use a small hand-roll. Format guaranteed to be IMF-fixdate per RFC 7231.
    case Regex.run(
           ~r/^[A-Za-z]+, (\d{2}) ([A-Za-z]+) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/,
           str
         ) do
      [_, day, mon, year, h, m, s] ->
        with {day, _} <- Integer.parse(day),
             {year, _} <- Integer.parse(year),
             {h, _} <- Integer.parse(h),
             {m, _} <- Integer.parse(m),
             {s, _} <- Integer.parse(s),
             month when is_integer(month) <- month_num(mon),
             {:ok, naive} <- NaiveDateTime.new(year, month, day, h, m, s),
             {:ok, dt} <- DateTime.from_naive(naive, "Etc/UTC") do
          {:ok, dt}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp month_num(name) do
    case Enum.find_index(@months, &(&1 == name)) do
      nil -> :error
      i -> i + 1
    end
  end
end
