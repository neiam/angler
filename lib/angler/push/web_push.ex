defmodule Angler.Push.WebPush do
  @moduledoc """
  Encrypts a Web Push payload for one subscription and POSTs it to the
  subscription's endpoint, signed with the instance's VAPID key.

  This is what `:web_push_encryption` 0.3.1 did, carried over so the
  send goes through Req: that package's only HTTP client is HTTPoison
  1.x, which holds hackney 1.x (known vulnerabilities, fixed only in
  hackney 4) in the tree. The encryption and the VAPID JWT are the
  package's own (MIT, Daniel Perez,
  https://github.com/tuvistavie/elixir-web-push-encryption), unchanged:
  the `aesgcm` content encoding (draft-ietf-webpush-encryption-04), an
  ES256 VAPID JWT good for 12 hours, a TTL of 0, and the GCM/FCM
  rewrites for the legacy endpoints. Only the transport differs; it no
  longer forces TLS 1.2, so a push service may negotiate 1.3.

  VAPID details come from `config :angler, :vapid_details` (subject,
  public_key, private_key; set in `runtime.exs` from the `PUSH_VAPID_*`
  env vars).
  """

  @max_payload_length 4078
  @auth_info "Content-Encoding: auth" <> <<0>>

  @gcm_url "https://android.googleapis.com/gcm/send"
  @temp_gcm_url "https://gcm-http.googleapis.com/gcm"
  @fcm_url "https://fcm.googleapis.com/fcm/send"

  # What HTTPoison (hackney) gave the send before: 8s to connect, 5s
  # for the response. No retries here; the Oban job retries.
  @connect_timeout 8_000
  @receive_timeout 5_000

  @type subscription :: %{endpoint: String.t(), keys: %{p256dh: String.t(), auth: String.t()}}

  @doc """
  Encrypt `message` for `subscription` and POST it to its endpoint.

  Returns `{:ok, %Req.Response{}}` for any HTTP response, whatever its
  status, and `{:error, exception}` when there was none.
  """
  @spec send_web_push(binary(), subscription(), String.t() | nil, non_neg_integer()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def send_web_push(message, subscription, auth_token \\ nil, ttl \\ 0)

  def send_web_push(_message, _subscription, _auth_token, ttl)
      when not is_integer(ttl) or ttl < 0 do
    raise ArgumentError, "send_web_push expects a non-negative integer ttl"
  end

  def send_web_push(_message, %{endpoint: @gcm_url <> _}, nil, _ttl) do
    raise ArgumentError, "send_web_push requires an auth_token for gcm endpoints"
  end

  def send_web_push(message, %{endpoint: endpoint} = subscription, auth_token, ttl) do
    payload = encrypt(message, subscription)
    vapid = vapid_headers(audience(endpoint), Application.fetch_env!(:angler, :vapid_details))

    headers =
      Map.merge(vapid, %{
        "TTL" => to_string(ttl),
        "Content-Encoding" => "aesgcm",
        "Encryption" => "salt=#{ub64(payload.salt)}",
        "Crypto-Key" => "dh=#{ub64(payload.server_public_key)};" <> vapid["Crypto-Key"]
      })

    {endpoint, headers} = request_params(endpoint, headers, auth_token)

    [
      url: endpoint,
      headers: headers,
      body: payload.ciphertext,
      retry: false,
      connect_options: [timeout: @connect_timeout],
      receive_timeout: @receive_timeout
    ]
    |> Keyword.merge(Application.get_env(:angler, :req_options, []))
    |> Req.post()
  end

  def send_web_push(_message, _subscription, _auth_token, _ttl) do
    raise ArgumentError,
          "send_web_push expects a subscription endpoint with an endpoint parameter"
  end

  @doc """
  Encrypt `message` for `subscription` (`aesgcm`), returning the
  ciphertext and the salt and server public key the receiver needs.
  """
  @spec encrypt(binary(), subscription(), non_neg_integer()) :: %{
          ciphertext: binary(),
          salt: binary(),
          server_public_key: binary()
        }
  def encrypt(message, subscription, padding_length \\ 0)

  def encrypt(message, _subscription, padding_length)
      when byte_size(message) + padding_length > @max_payload_length do
    raise ArgumentError,
          "Payload is too large. The current length is #{byte_size(message)} bytes plus" <>
            " #{padding_length} bytes of padding but the max length is #{@max_payload_length} bytes"
  end

  def encrypt(message, subscription, padding_length) do
    plaintext =
      <<padding_length::unsigned-big-16>> <> :binary.copy(<<0>>, padding_length) <> message

    {client_public_key, client_auth_token} = client_keys(subscription)

    salt = :crypto.strong_rand_bytes(16)
    {server_public_key, server_private_key} = :crypto.generate_key(:ecdh, :prime256v1)
    shared_secret = :crypto.compute_key(:ecdh, client_public_key, server_private_key, :prime256v1)

    prk = hkdf(client_auth_token, shared_secret, @auth_info, 32)
    context = context(client_public_key, server_public_key)
    key = hkdf(salt, prk, info("aesgcm", context), 16)
    nonce = hkdf(salt, prk, info("nonce", context), 12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, key, nonce, plaintext, "", true)

    %{ciphertext: ciphertext <> tag, salt: salt, server_public_key: server_public_key}
  end

  defp client_keys(%{keys: %{p256dh: p256dh, auth: auth}})
       when not is_nil(p256dh) and not is_nil(auth) do
    client_public_key = Base.url_decode64!(p256dh, padding: false)
    client_auth_token = Base.url_decode64!(auth, padding: false)

    if byte_size(client_auth_token) != 16,
      do: raise(ArgumentError, "Subscription's Auth token is not 16 bytes.")

    if byte_size(client_public_key) != 65,
      do: raise(ArgumentError, "Subscription's client key (p256dh) is invalid.")

    {client_public_key, client_auth_token}
  end

  defp client_keys(_subscription) do
    raise ArgumentError, "Subscription is missing some encryption details."
  end

  defp hkdf(salt, ikm, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)

    :crypto.mac(:hmac, :sha256, prk, [info, <<1>>])
    |> :binary.part(0, length)
  end

  defp context(client_public_key, server_public_key) do
    <<0, byte_size(client_public_key)::unsigned-big-16>> <>
      client_public_key <>
      <<byte_size(server_public_key)::unsigned-big-16>> <> server_public_key
  end

  defp info(type, context), do: "Content-Encoding: " <> type <> <<0>> <> "P-256" <> context

  @doc false
  # The VAPID headers for `aesgcm`: a WebPush JWT signed with the
  # instance key, and the key itself in Crypto-Key.
  @spec vapid_headers(String.t(), keyword() | map(), pos_integer()) :: %{String.t() => String.t()}
  def vapid_headers(audience, vapid, expiration \\ 12 * 3600) do
    public_key = Base.url_decode64!(vapid[:public_key], padding: false)
    private_key = Base.url_decode64!(vapid[:private_key], padding: false)

    claims =
      JOSE.JWT.from_map(%{
        aud: audience,
        exp: DateTime.to_unix(DateTime.utc_now()) + expiration,
        sub: vapid[:subject]
      })

    jwk =
      JOSE.JWK.from_key(
        {:ECPrivateKey, 1, private_key, {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}}, public_key,
         nil}
      )

    {_, jwt} = JOSE.JWS.compact(JOSE.JWT.sign(jwk, %{"alg" => "ES256"}, claims))
    %{"Authorization" => "WebPush " <> jwt, "Crypto-Key" => "p256ecdsa=" <> vapid[:public_key]}
  end

  defp request_params(endpoint, headers, auth_token) do
    cond do
      String.starts_with?(endpoint, @gcm_url) ->
        {String.replace(endpoint, @gcm_url, @temp_gcm_url),
         Map.put(headers, "Authorization", "key=#{auth_token}")}

      String.starts_with?(endpoint, @fcm_url) and not is_nil(auth_token) ->
        {endpoint, Map.put(headers, "Authorization", "key=#{auth_token}")}

      true ->
        {endpoint, headers}
    end
  end

  defp audience(endpoint) do
    uri = URI.parse(endpoint)
    uri.scheme <> "://" <> uri.host
  end

  defp ub64(value), do: Base.url_encode64(value, padding: false)
end
