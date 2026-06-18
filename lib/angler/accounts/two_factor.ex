defmodule Angler.Accounts.TwoFactor do
  @moduledoc """
  Time-based one-time passwords (RFC 6238) + recovery codes, ported from the
  git_gud reference but adapted to Angler's `users` schema, which stores both
  the TOTP secret and the recovery-code set as single encrypted blobs
  (`two_factor_secret_enc`, `two_factor_recovery_enc`) rather than split columns
  and a side table.

  States:

    * **Disabled** — `two_factor_enabled_at` is nil and no secret. Login skips
      the second factor.
    * **Enabled** — secret + `two_factor_enabled_at` set. Web login and the
      mobile `POST /oauth/token` require a valid 6-digit code or a one-shot
      recovery code.

  Secrets go through `Angler.Accounts.Secrets` (AES-256-GCM). Recovery codes are
  ten random strings kept (plaintext) inside the encrypted recovery blob; a code
  is marked used on first redemption.
  """

  import Ecto.Query, warn: false

  alias Angler.Accounts.{Secrets, User, Webauthn}
  alias Angler.Repo

  @recovery_code_count 10
  @recovery_code_bytes 6
  @issuer "Angler"

  ## ── enrollment ──────────────────────────────────────────────────────

  @doc "A fresh raw TOTP secret. Keep it in the enrollment session until `enable/3`."
  def new_secret, do: NimbleTOTP.secret()

  @doc "`otpauth://` URI to seed authenticator apps (usually rendered via `qr_svg/1`)."
  def provisioning_uri(secret, %User{email: email}) do
    NimbleTOTP.otpauth_uri("#{@issuer}:#{email}", secret, issuer: @issuer)
  end

  @doc "Render a provisioning URI as an inline SVG QR code."
  def qr_svg(uri) do
    uri
    |> EQRCode.encode()
    |> EQRCode.svg(width: 220, background_color: "#ffffff", color: "#000000")
  end

  @doc """
  Verify `code` against `secret`; on match persist the encrypted secret, mint
  recovery codes, and mark 2FA enabled. Returns `{:ok, plaintext_codes}` (shown
  once) or `{:error, :invalid_code}`.
  """
  def enable(%User{} = user, secret, code) when is_binary(secret) and is_binary(code) do
    if NimbleTOTP.valid?(secret, code) do
      codes = gen_codes()

      {:ok, _} =
        user
        |> Ecto.Changeset.change(
          two_factor_secret_enc: Secrets.encrypt(secret),
          two_factor_recovery_enc: encode_codes(codes),
          two_factor_enabled_at: DateTime.utc_now()
        )
        |> Repo.update()

      {:ok, codes}
    else
      {:error, :invalid_code}
    end
  end

  @doc """
  Turn TOTP off. The recovery blob is kept if the user still has a WebAuthn
  credential (it remains a fallback for that factor); otherwise it's cleared.
  """
  def disable(%User{} = user) do
    keep_recovery? = Webauthn.has_credentials?(user)

    user
    |> Ecto.Changeset.change(
      two_factor_secret_enc: nil,
      two_factor_recovery_enc: if(keep_recovery?, do: user.two_factor_recovery_enc, else: nil),
      two_factor_enabled_at: nil
    )
    |> Repo.update()
  end

  ## ── verification ────────────────────────────────────────────────────

  @doc "True once the user has finished enrolling TOTP."
  def enabled?(%User{two_factor_enabled_at: nil}), do: false
  def enabled?(%User{}), do: true

  @doc "True if the user has any second factor (TOTP or a security key)."
  def any_factor?(%User{} = user), do: enabled?(user) or Webauthn.has_credentials?(user)

  @doc "Verify a 6-digit TOTP code. `:ok` | `{:error, :invalid_code | :not_enrolled}`."
  def verify_code(%User{two_factor_secret_enc: nil}, _code), do: {:error, :not_enrolled}

  def verify_code(%User{} = user, code) when is_binary(code) do
    with {:ok, secret} <- Secrets.decrypt(user.two_factor_secret_enc) do
      if NimbleTOTP.valid?(secret, code), do: :ok, else: {:error, :invalid_code}
    end
  end

  ## ── recovery codes ──────────────────────────────────────────────────

  @doc """
  Consume a recovery code: mark it used and return `:ok`, or `{:error,
  :invalid_code}`. Matching is constant-ish over the small code set.
  """
  def verify_recovery_code(%User{} = user, code) when is_binary(code) do
    code = String.trim(code)
    codes = decode_codes(user.two_factor_recovery_enc)

    case Enum.find_index(codes, fn c -> c["code"] == code and c["used"] != true end) do
      nil ->
        {:error, :invalid_code}

      idx ->
        updated = List.update_at(codes, idx, &Map.put(&1, "used", true))

        {:ok, _} =
          user
          |> Ecto.Changeset.change(two_factor_recovery_enc: encode_codes_raw(updated))
          |> Repo.update()

        :ok
    end
  end

  @doc "Count of unused recovery codes."
  def remaining_recovery_codes(%User{two_factor_recovery_enc: nil}), do: 0

  def remaining_recovery_codes(%User{two_factor_recovery_enc: blob}) do
    blob |> decode_codes() |> Enum.count(fn c -> c["used"] != true end)
  end

  @doc "Replace all recovery codes with a fresh batch. Returns the plaintext codes."
  def regenerate_recovery_codes!(%User{} = user) do
    codes = gen_codes()

    {:ok, _} =
      user
      |> Ecto.Changeset.change(two_factor_recovery_enc: encode_codes(codes))
      |> Repo.update()

    codes
  end

  @doc """
  Ensure the user has at least one unused recovery code; mint a batch if not.
  Returns the plaintext codes, or `nil` if they already had some. Called from
  first-factor enrollment paths (e.g. registering a WebAuthn key without TOTP).
  """
  def ensure_recovery_codes(%User{} = user) do
    if remaining_recovery_codes(user) > 0 do
      nil
    else
      regenerate_recovery_codes!(user)
    end
  end

  ## ── instance enforcement ────────────────────────────────────────────

  @doc "Whether TOTP is required by instance policy for new accounts."
  def required?, do: Keyword.get(cfg(), :required, false)

  @doc "Grace-period days before enforcement kicks in (default 14)."
  def grace_period_days, do: Keyword.get(cfg(), :grace_period_days, 14)

  @doc """
  Enrollment status for an authed user: `:not_required`, `:enrolled`,
  `{:grace, days_left}`, or `:enforced`.
  """
  def enforcement_status(%User{} = user) do
    cond do
      not required?() -> :not_required
      enabled?(user) -> :enrolled
      true -> in_grace?(user)
    end
  end

  ## ── internals ───────────────────────────────────────────────────────

  defp gen_codes, do: for(_ <- 1..@recovery_code_count, do: gen_code())

  defp gen_code do
    :crypto.strong_rand_bytes(@recovery_code_bytes)
    |> Base.encode32(case: :lower, padding: false)
    |> String.slice(0, 10)
  end

  # Plaintext codes -> encrypted JSON blob of `[%{"code","used"}]`.
  defp encode_codes(codes) when is_list(codes) do
    codes
    |> Enum.map(&%{"code" => &1, "used" => false})
    |> encode_codes_raw()
  end

  defp encode_codes_raw(list), do: Secrets.encrypt(Jason.encode!(list))

  defp decode_codes(nil), do: []

  defp decode_codes(blob) do
    case Secrets.decrypt(blob) do
      {:ok, json} -> Jason.decode!(json)
      _ -> []
    end
  end

  defp in_grace?(%User{} = user) do
    case user.inserted_at do
      %DateTime{} = dt ->
        elapsed = DateTime.diff(DateTime.utc_now(), dt)
        grace = grace_period_days() * 86_400

        if elapsed >= grace,
          do: :enforced,
          else: {:grace, max(0, div(grace - elapsed, 86_400))}

      _ ->
        {:grace, grace_period_days()}
    end
  end

  defp cfg, do: Application.get_env(:angler, __MODULE__, [])
end
