defmodule Angler.Accounts.Secrets do
  @moduledoc """
  AES-256-GCM encryption for small secrets stored at rest — currently the
  two-factor TOTP secret and recovery-code blob on the `users` row.

  The master key is base64-encoded in
  `config :angler, Angler.Accounts.Secrets, master_key: "..."` and must decode
  to 32 bytes. A DEV/TEST default ships in `config.exs`; production overrides it
  from `TWO_FACTOR_MASTER_KEY` in `runtime.exs`.

  Ciphertext is packed into a single binary so it fits one DB column:

      <<iv::binary-12, tag::binary-16, ciphertext::binary>>

  (No per-row key id — rotation invalidates existing blobs, which is acceptable
  for 2FA: a user simply re-enrolls.)
  """

  @aad "angler-2fa-v1"

  @doc "Encrypt `plaintext`, returning the packed binary blob."
  @spec encrypt(binary()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, master_key(), iv, plaintext, @aad, true)

    iv <> tag <> ciphertext
  end

  @doc "Decrypt a packed blob produced by `encrypt/1`."
  @spec decrypt(binary()) :: {:ok, binary()} | {:error, :decrypt_failed | :malformed}
  def decrypt(<<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           master_key(),
           iv,
           ciphertext,
           @aad,
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :decrypt_failed}
    end
  end

  def decrypt(_), do: {:error, :malformed}

  defp master_key do
    cfg = Application.get_env(:angler, __MODULE__, [])
    b64 = Keyword.fetch!(cfg, :master_key)
    key = Base.decode64!(b64)

    if byte_size(key) != 32 do
      raise "Angler.Accounts.Secrets master_key must decode to 32 bytes"
    end

    key
  end
end
