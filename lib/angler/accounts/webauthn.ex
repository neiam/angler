defmodule Angler.Accounts.Webauthn do
  @moduledoc """
  WebAuthn (FIDO2 / U2F) credentials — hardware security keys, platform
  authenticators (Touch ID / Windows Hello), and passkeys. Ported from the
  git_gud reference.

  Sits alongside `Angler.Accounts.TwoFactor` (TOTP): a user may have one TOTP
  secret plus many security keys, and the login challenge accepts any valid
  factor. `Wax` handles the CBOR/COSE/attestation crypto; we persist only what
  survives verification.

  `rp_id`/`origin` default to the endpoint host/url, overridable via
  `config :angler, Angler.Accounts.Webauthn, rp_id: ..., origin: ...`.
  """

  import Ecto.Query, warn: false

  alias Angler.Accounts.{TwoFactor, User, WebauthnCredential}
  alias Angler.Repo

  ## ── relying party ───────────────────────────────────────────────────

  defp rp_id, do: cfg()[:rp_id] || endpoint_host()
  defp origin, do: cfg()[:origin] || AnglerWeb.Endpoint.url()
  defp endpoint_host, do: AnglerWeb.Endpoint.url() |> URI.parse() |> Map.get(:host) || "localhost"
  defp cfg, do: Application.get_env(:angler, __MODULE__, [])

  ## ── registration ────────────────────────────────────────────────────

  def registration_challenge(%User{} = _user) do
    Wax.new_registration_challenge(
      origin: origin(),
      rp_id: rp_id(),
      user_verification: "preferred",
      attestation: "none",
      trusted_attestation_types: [:none, :basic, :uncertain, :self, :attca]
    )
  end

  def serialize_registration_options(%User{} = user, %Wax.Challenge{} = challenge) do
    excluded =
      user
      |> list_credentials()
      |> Enum.map(fn c -> %{"type" => "public-key", "id" => b64u(c.credential_id)} end)

    %{
      "challenge" => b64u(challenge.bytes),
      "rp" => %{"id" => rp_id(), "name" => "Angler"},
      "user" => %{
        "id" => b64u(<<user.id::64>>),
        "name" => user.email,
        "displayName" => user.name || user.email
      },
      "pubKeyCredParams" => [
        %{"type" => "public-key", "alg" => -7},
        %{"type" => "public-key", "alg" => -257}
      ],
      "timeout" => 60_000,
      "attestation" => "none",
      "authenticatorSelection" => %{
        "userVerification" => "preferred",
        "residentKey" => "preferred"
      },
      "excludeCredentials" => excluded
    }
  end

  def register_credential(%User{} = user, %{} = body, %Wax.Challenge{} = challenge) do
    with {:ok, attestation_object} <- b64u_decode(body["attestationObject"]),
         {:ok, client_data_json} <- b64u_decode(body["clientDataJSON"]),
         {:ok, {auth_data, _attestation}} <-
           Wax.register(attestation_object, client_data_json, challenge) do
      acd = auth_data.attested_credential_data

      attrs = %{
        user_id: user.id,
        credential_id: acd.credential_id,
        public_key: :erlang.term_to_binary(acd.credential_public_key),
        sign_count: auth_data.sign_count,
        aaguid: format_aaguid(acd.aaguid),
        name: Map.get(body, "name") || "Security key"
      }

      case %WebauthnCredential{} |> WebauthnCredential.create_changeset(attrs) |> Repo.insert() do
        {:ok, cred} ->
          # First MFA enrollment via a key (no TOTP yet) still needs recovery codes.
          {:ok, cred, TwoFactor.ensure_recovery_codes(user)}

        err ->
          err
      end
    else
      {:error, _} = err -> err
      err -> {:error, err}
    end
  end

  defp format_aaguid(<<a::32, b::16, c::16, d::16, e::48>>) do
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  defp format_aaguid(_), do: nil

  ## ── authentication ──────────────────────────────────────────────────

  def authentication_challenge(%User{} = user) do
    allowed =
      user
      |> list_credentials()
      |> Enum.map(&{&1.credential_id, :erlang.binary_to_term(&1.public_key)})

    Wax.new_authentication_challenge(
      origin: origin(),
      rp_id: rp_id(),
      user_verification: "preferred",
      allow_credentials: allowed
    )
  end

  def serialize_authentication_options(%Wax.Challenge{} = challenge) do
    %{
      "challenge" => b64u(challenge.bytes),
      "rpId" => rp_id(),
      "timeout" => 60_000,
      "userVerification" => "preferred",
      "allowCredentials" =>
        Enum.map(challenge.allow_credentials, fn {id, _} ->
          %{"type" => "public-key", "id" => b64u(id)}
        end)
    }
  end

  def verify_assertion(%User{} = user, %{} = body, %Wax.Challenge{} = challenge) do
    with {:ok, credential_id} <- b64u_decode(body["id"]),
         {:ok, auth_data} <- b64u_decode(body["authenticatorData"]),
         {:ok, signature} <- b64u_decode(body["signature"]),
         {:ok, client_data_json} <- b64u_decode(body["clientDataJSON"]),
         %WebauthnCredential{} = cred <- find_credential(user, credential_id),
         {:ok, %Wax.AuthenticatorData{} = decoded} <-
           Wax.authenticate(credential_id, auth_data, signature, client_data_json, challenge) do
      cred |> WebauthnCredential.usage_changeset(decoded.sign_count) |> Repo.update()
    else
      nil -> {:error, :unknown_credential}
      {:error, _} = err -> err
      err -> {:error, err}
    end
  end

  defp find_credential(%User{id: uid}, credential_id) do
    Repo.get_by(WebauthnCredential, user_id: uid, credential_id: credential_id)
  end

  ## ── CRUD ────────────────────────────────────────────────────────────

  def list_credentials(%User{id: uid}) do
    Repo.all(
      from c in WebauthnCredential, where: c.user_id == ^uid, order_by: [desc: c.inserted_at]
    )
  end

  def get_credential(%User{id: uid}, id) do
    Repo.get_by(WebauthnCredential, id: id, user_id: uid)
  end

  def delete_credential(%WebauthnCredential{} = cred), do: Repo.delete(cred)

  def rename_credential(%WebauthnCredential{} = cred, name) do
    cred |> WebauthnCredential.rename_changeset(name) |> Repo.update()
  end

  def has_credentials?(%User{id: uid}) do
    Repo.exists?(from c in WebauthnCredential, where: c.user_id == ^uid)
  end

  def count(%User{id: uid}) do
    Repo.aggregate(from(c in WebauthnCredential, where: c.user_id == ^uid), :count)
  end

  ## ── base64url ───────────────────────────────────────────────────────

  defp b64u(bin), do: Base.url_encode64(bin, padding: false)

  defp b64u_decode(nil), do: {:error, :missing}

  defp b64u_decode(s) when is_binary(s) do
    case Base.url_decode64(s, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :bad_base64}
    end
  end
end
