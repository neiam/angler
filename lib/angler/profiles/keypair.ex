defmodule Angler.Profiles.Keypair do
  @moduledoc """
  RSA-2048 keypair generation for local profiles.

  Generated at profile-create time so every local actor can sign outbound
  ActivityPub. Public PEM is `BEGIN PUBLIC KEY` (SubjectPublicKeyInfo) form,
  matching what Mastodon and other AP peers expect.
  """

  @doc "Returns `{public_pem, private_pem}`."
  @spec generate() :: {String.t(), binary()}
  def generate do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    {:RSAPrivateKey, _v, n, e, _d, _p, _q, _dmp1, _dmq1, _iqmp, _other} = private
    public = {:RSAPublicKey, n, e}

    private_pem =
      [:public_key.pem_entry_encode(:RSAPrivateKey, private)]
      |> :public_key.pem_encode()

    public_pem =
      [:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public)]
      |> :public_key.pem_encode()

    {public_pem, private_pem}
  end
end
