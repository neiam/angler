defmodule Angler.Federation.HTTPSignatureTest do
  use ExUnit.Case, async: true

  alias Angler.Federation.HTTPSignature
  alias Angler.Profiles.Keypair

  setup do
    {public_pem, private_pem} = Keypair.generate()
    %{public_pem: public_pem, private_pem: private_pem}
  end

  describe "sign/7 + verify/5 round-trip" do
    test "happy path", %{public_pem: pub, private_pem: priv} do
      key_id = "https://remote.test/users/x#main-key"
      body = ~s({"type":"Follow","actor":"https://remote.test/users/x"})

      {:ok, headers} =
        HTTPSignature.sign(:post, "/users/y/inbox", "local.test", body, key_id, priv, [
          {"Content-Type", "application/activity+json"}
        ])

      lower = Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)
      resolver = fn ^key_id -> {:ok, pub} end

      assert :ok = HTTPSignature.verify(:post, "/users/y/inbox", lower, body, resolver)
    end

    test "tampered body fails digest check", %{public_pem: pub, private_pem: priv} do
      key_id = "https://remote.test/users/x#main-key"

      {:ok, headers} =
        HTTPSignature.sign(:post, "/users/y/inbox", "local.test", "original", key_id, priv, [])

      lower = Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)
      resolver = fn ^key_id -> {:ok, pub} end

      assert {:error, :bad_digest} =
               HTTPSignature.verify(:post, "/users/y/inbox", lower, "tampered", resolver)
    end

    test "tampered path fails signature check", %{public_pem: pub, private_pem: priv} do
      key_id = "https://remote.test/users/x#main-key"
      body = "{}"

      {:ok, headers} =
        HTTPSignature.sign(:post, "/users/y/inbox", "local.test", body, key_id, priv, [])

      lower = Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)
      resolver = fn ^key_id -> {:ok, pub} end

      assert {:error, :bad_signature} =
               HTTPSignature.verify(:post, "/users/z/inbox", lower, body, resolver)
    end

    test "missing signature header → :missing_signature" do
      assert {:error, :missing_signature} =
               HTTPSignature.verify(:post, "/", [], "", fn _ -> :error end)
    end

    test "key_resolver returning :error → :key_not_found", %{private_pem: priv} do
      key_id = "https://remote.test/users/x#main-key"
      body = "{}"

      {:ok, headers} =
        HTTPSignature.sign(:post, "/inbox", "local.test", body, key_id, priv, [])

      lower = Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)

      assert {:error, :key_not_found} =
               HTTPSignature.verify(:post, "/inbox", lower, body, fn _ -> :error end)
    end

    test "stale Date → :date_skew", %{public_pem: pub, private_pem: priv} do
      key_id = "https://remote.test/users/x#main-key"
      body = "{}"

      {:ok, headers} =
        HTTPSignature.sign(:post, "/inbox", "local.test", body, key_id, priv, [])

      lower =
        headers
        |> Enum.map(fn {k, v} -> {String.downcase(k), v} end)
        |> Enum.map(fn
          {"date", _} -> {"date", HTTPSignature.http_date(~U[2000-01-01 00:00:00Z])}
          other -> other
        end)

      resolver = fn ^key_id -> {:ok, pub} end

      assert {:error, :date_skew} = HTTPSignature.verify(:post, "/inbox", lower, body, resolver)
    end
  end

  describe "parse_signature_header/1" do
    test "parses a real-world signature header" do
      raw =
        ~S|keyId="https://remote/users/x#main-key",algorithm="rsa-sha256",headers="(request-target) host date digest",signature="abc=="|

      {:ok, parts} = HTTPSignature.parse_signature_header(raw)
      assert parts["keyId"] == "https://remote/users/x#main-key"
      assert parts["algorithm"] == "rsa-sha256"
      assert parts["headers"] == "(request-target) host date digest"
      assert parts["signature"] == "abc=="
    end
  end
end
