defmodule Angler.Federation.Sync do
  @moduledoc """
  Pieces shared by the two digest-driven synchronizations, FEP-8fcf
  followers (`Angler.Federation.FollowersSync`) and FEP-070c blocks
  (`Angler.Federation.BlockSync`): actor ids compared by authority, the
  XOR-of-SHA-256 digest, `k="v"` header parameters, and signed fetches of
  a peer's collection that never leave its server.
  """

  alias Angler.Federation.{HTTP, InstanceActor}

  @empty_digest String.duplicate("0", 64)
  @collection_types ~w(Collection OrderedCollection CollectionPage OrderedCollectionPage)

  @doc "The digest of nothing."
  def empty_digest, do: @empty_digest

  @doc """
  Scheme and authority of an http(s) URL, lowercased and without a default
  port, or nil.
  """
  @spec authority(term()) :: String.t() | nil
  def authority(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host, port: port, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        default = if scheme == "https", do: 443, else: 80
        base = scheme <> "://" <> String.downcase(host)
        if port in [nil, default], do: base, else: base <> ":" <> Integer.to_string(port)

      _ ->
        nil
    end
  end

  def authority(_), do: nil

  @doc "Our own authority."
  def local_authority, do: authority(AnglerWeb.Endpoint.url())

  @doc "The host of an authority, or nil."
  def host(authority) when is_binary(authority), do: URI.parse(authority).host
  def host(_), do: nil

  @doc "The FEP digest: SHA-256 of each string, XORed together, hex."
  @spec digest([String.t()]) :: String.t()
  def digest(ids) do
    ids
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.reduce(<<0::256>>, fn id, acc ->
      :crypto.exor(acc, :crypto.hash(:sha256, id))
    end)
    |> Base.encode16(case: :lower)
  end

  @doc "A lowercased 64-hex-digit digest, or nil."
  def normalize_digest(value) when is_binary(value) do
    value = String.downcase(value)
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value), do: value
  end

  def normalize_digest(_), do: nil

  @doc """
  The `k="v"` parameters of a header value (Signature style), or `:error`
  when it's too long or names a parameter twice.
  """
  @spec parse_params(term()) :: {:ok, %{String.t() => String.t()}} | :error
  def parse_params(value) when is_binary(value) and byte_size(value) <= 2048 do
    pairs = Regex.scan(~r/(?:^|,)\s*([A-Za-z][A-Za-z0-9_-]*)\s*=\s*"([^"]*)"/, value)
    params = Map.new(pairs, fn [_, k, v] -> {k, v} end)
    if length(pairs) == map_size(params), do: {:ok, params}, else: :error
  end

  def parse_params(_), do: :error

  @doc "The username in one of our actor ids, or nil if it isn't one."
  @spec local_username(term()) :: String.t() | nil
  def local_username(uri) when is_binary(uri) do
    with true <- authority(uri) == local_authority(),
         %URI{query: nil, fragment: nil, path: path} when is_binary(path) <- URI.parse(uri),
         [_, name] <- Regex.run(~r"\A/users/([A-Za-z0-9_.\-]{1,64})/?\z", path) do
      name
    else
      _ -> nil
    end
  end

  def local_username(_), do: nil

  @doc "GET a document signed as the instance actor, only if it's on `authority`."
  @spec fetch_doc(String.t(), String.t()) :: map() | nil
  def fetch_doc(url, authority) do
    if authority(url) == authority do
      actor = InstanceActor.ensure!()

      case HTTP.fetch(url, signed_with: {actor.key_id, actor.private_key_pem}) do
        {:ok, %{} = doc} -> doc
        _ -> nil
      end
    end
  end

  @doc "Whether a document is one of the AS collection or page types."
  def collection?(%{"type" => types}),
    do: types |> List.wrap() |> Enum.any?(&(&1 in @collection_types))

  def collection?(_), do: false

  @doc "Whether a collection carries its items inline."
  def items?(doc), do: Map.has_key?(doc, "orderedItems") or Map.has_key?(doc, "items")
end
