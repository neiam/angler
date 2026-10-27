defmodule Angler.Push.WebPushTest do
  # async: false — the stubbed send tests set :angler, :req_options.
  use ExUnit.Case, async: false

  alias Angler.Push.Sender
  alias Angler.Push.WebPush

  # A browser's side of a subscription: its ECDH keypair and auth secret.
  defp client(endpoint \\ "https://push.example/abc") do
    {pub, priv} = :crypto.generate_key(:ecdh, :prime256v1)
    auth = :crypto.strong_rand_bytes(16)

    sub = %{
      endpoint: endpoint,
      keys: %{
        p256dh: Base.url_encode64(pub, padding: false),
        auth: Base.url_encode64(auth, padding: false)
      }
    }

    {sub, pub, priv, auth}
  end

  # The receiving end of aesgcm, written out independently of WebPush.
  defp decrypt(ciphertext, salt, server_pub, client_pub, client_priv, auth) do
    hkdf = fn salt, ikm, info, len ->
      prk = :crypto.mac(:hmac, :sha256, salt, ikm)
      :crypto.mac(:hmac, :sha256, prk, info <> <<1>>) |> binary_part(0, len)
    end

    shared = :crypto.compute_key(:ecdh, server_pub, client_priv, :prime256v1)
    prk = hkdf.(auth, shared, "Content-Encoding: auth\0", 32)
    context = <<0, 65::16>> <> client_pub <> <<65::16>> <> server_pub
    key = hkdf.(salt, prk, "Content-Encoding: aesgcm\0P-256" <> context, 16)
    nonce = hkdf.(salt, prk, "Content-Encoding: nonce\0P-256" <> context, 12)

    body = binary_part(ciphertext, 0, byte_size(ciphertext) - 16)
    tag = binary_part(ciphertext, byte_size(ciphertext), -16)

    <<pad::16, rest::binary>> =
      :crypto.crypto_one_time_aead(:aes_128_gcm, key, nonce, body, "", tag, false)

    binary_part(rest, pad, byte_size(rest) - pad)
  end

  defp header_params(value) do
    value
    |> String.split(";")
    |> Map.new(fn kv ->
      [k, v] = String.split(kv, "=", parts: 2)
      {k, v}
    end)
  end

  describe "encrypt/3" do
    test "the subscriber can decrypt what it produces" do
      {sub, pub, priv, auth} = client()

      for padding <- [0, 7] do
        %{ciphertext: ct, salt: salt, server_public_key: spk} =
          WebPush.encrypt(~s({"title":"hi"}), sub, padding)

        assert byte_size(salt) == 16
        assert decrypt(ct, salt, spk, pub, priv, auth) == ~s({"title":"hi"})
      end
    end

    test "rejects a subscription with malformed keys" do
      {sub, _, _, _} = client()

      assert_raise ArgumentError, fn ->
        WebPush.encrypt("x", put_in(sub.keys.auth, Base.url_encode64("short", padding: false)))
      end

      assert_raise ArgumentError, fn -> WebPush.encrypt("x", %{endpoint: sub.endpoint}) end
    end

    test "rejects a payload over the limit" do
      {sub, _, _, _} = client()
      assert_raise ArgumentError, fn -> WebPush.encrypt(String.duplicate("a", 4079), sub) end
    end
  end

  describe "over the wire" do
    # A real local server, not a Req.Test stub: Req's plug adapter strips
    # content-encoding, which is exactly the header to check here.
    test "POSTs the encrypted body with the aesgcm and VAPID headers" do
      server =
        start_supervised!(
          {Bandit,
           plug: {Angler.Test.CapturePlug, test: self()},
           ip: :loopback,
           port: 0,
           startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      {sub, pub, priv, auth} = client("http://127.0.0.1:#{port}/abc")

      assert {:ok, %{status_code: 201}} = Sender.WebPush.send("hello", sub)

      assert_received {:captured, "POST", "/abc", headers, body}
      headers = Map.new(headers)

      assert headers["content-encoding"] == "aesgcm"
      assert headers["ttl"] == "0"
      assert "salt=" <> salt = headers["encryption"]

      crypto_key = header_params(headers["crypto-key"])
      vapid = Application.fetch_env!(:angler, :vapid_details)
      assert crypto_key["p256ecdsa"] == vapid[:public_key]

      server_pub = Base.url_decode64!(crypto_key["dh"], padding: false)
      salt = Base.url_decode64!(salt, padding: false)
      assert decrypt(body, salt, server_pub, pub, priv, auth) == "hello"

      assert "WebPush " <> jwt = headers["authorization"]
      claims = jwt |> JOSE.JWT.peek_payload() |> Map.get(:fields)
      assert claims["aud"] == "http://127.0.0.1"
      assert claims["sub"] == vapid[:subject]
      assert claims["exp"] > System.os_time(:second)
    end
  end

  describe "the production sender's results" do
    setup do
      Application.put_env(:angler, :req_options, plug: {Req.Test, :web_push})
      on_exit(fn -> Application.delete_env(:angler, :req_options) end)
      :ok
    end

    test "hands back the status of a rejected push" do
      {sub, _, _, _} = client()
      Req.Test.stub(:web_push, &Plug.Conn.send_resp(&1, 410, ""))
      assert {:ok, %{status_code: 410}} = Sender.WebPush.send("hello", sub)
    end

    test "a transport error is an error" do
      {sub, _, _, _} = client()
      Req.Test.stub(:web_push, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Sender.WebPush.send("hello", sub)
    end
  end
end
