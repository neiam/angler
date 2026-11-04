defmodule AnglerWeb.WebauthnController do
  @moduledoc """
  JSON endpoints backing the browser WebAuthn ceremonies (see
  `assets/js/webauthn.js`).

    * `POST /api/webauthn/register/start|finish` — register a key for the
      logged-in user (session auth).
    * `POST /api/webauthn/auth/start|finish` — prove a security key during the
      2FA login challenge (pending `:two_factor_user_id` in session).

  The `Wax.Challenge` is stashed in the session between start and finish so the
  finish step verifies against the exact challenge it issued.
  """

  use AnglerWeb, :controller

  alias Angler.Accounts
  alias Angler.Accounts.Webauthn

  ## ── registration (authenticated user) ───────────────────────────────

  def register_start(conn, _params) do
    case conn.assigns[:current_user] do
      %{} = user ->
        challenge = Webauthn.registration_challenge(user)

        conn
        |> put_session(:webauthn_reg_challenge, stash(challenge))
        |> json(%{"publicKey" => Webauthn.serialize_registration_options(user, challenge)})

      _ ->
        unauthorized(conn)
    end
  end

  def register_finish(conn, params) do
    with %{} = user <- conn.assigns[:current_user],
         %Wax.Challenge{} = challenge <- unstash(get_session(conn, :webauthn_reg_challenge)),
         {:ok, cred, recovery_codes} <- Webauthn.register_credential(user, params, challenge) do
      conn
      |> delete_session(:webauthn_reg_challenge)
      |> json(%{
        "ok" => true,
        "id" => cred.id,
        "name" => cred.name,
        "recoveryCodes" => recovery_codes
      })
    else
      nil -> unauthorized(conn)
      {:error, reason} -> error(conn, "registration failed: #{inspect(reason)}")
    end
  end

  ## ── authentication (mid-2FA challenge) ───────────────────────────────

  def auth_start(conn, _params) do
    with id when is_integer(id) <- get_session(conn, :two_factor_user_id),
         %{} = user <- Accounts.get_user(id) do
      challenge = Webauthn.authentication_challenge(user)

      conn
      |> put_session(:webauthn_auth_challenge, stash(challenge))
      |> json(%{"publicKey" => Webauthn.serialize_authentication_options(challenge)})
    else
      _ -> unauthorized(conn)
    end
  end

  def auth_finish(conn, params) do
    with id when is_integer(id) <- get_session(conn, :two_factor_user_id),
         %{} = user <- Accounts.get_user(id),
         %Wax.Challenge{} = challenge <- unstash(get_session(conn, :webauthn_auth_challenge)),
         {:ok, _cred} <- Webauthn.verify_assertion(user, params, challenge) do
      conn
      |> delete_session(:webauthn_auth_challenge)
      # Proof the completion controller checks against the pending user.
      |> put_session(:two_factor_passed_user_id, id)
      |> json(%{"ok" => true, "redirect" => ~p"/login/two-factor/complete"})
    else
      _ -> error(conn, "verification failed")
    end
  end

  ## ── session stash for the Wax.Challenge ──────────────────────────────

  defp stash(challenge), do: Base.encode64(:erlang.term_to_binary(challenge))

  defp unstash(nil), do: nil

  defp unstash(b64) do
    case Base.decode64(b64) do
      {:ok, bin} -> :erlang.binary_to_term(bin, [:safe])
      _ -> nil
    end
  end

  defp unauthorized(conn), do: conn |> put_status(401) |> json(%{"error" => "unauthorized"})
  defp error(conn, msg), do: conn |> put_status(422) |> json(%{"error" => msg})
end
