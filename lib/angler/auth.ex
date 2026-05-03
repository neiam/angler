defmodule Angler.Auth do
  @moduledoc """
  In-app registration code lifecycle.

  Pixelfed's flow:

  1. User submits email → we generate a 6-digit code, store its hash, email
     the plaintext, return success.
  2. User submits email + code → we verify the code matches; this **does not
     consume** the code (matches Pixelfed's `app-code-verify`).
  3. User submits email + code + username + password → we re-verify and create
     the account, deleting the `app_registers` row on success (matches
     Pixelfed's `onboarding`).
  """

  import Ecto.Query, warn: false
  alias Angler.Auth.AppRegister
  alias Angler.Repo

  @code_max_attempts 5
  # Pixelfed allows codes for 90 days; we tighten to 24h. Operators who want a
  # longer window can override via Angler.Config later.
  @code_ttl_seconds 24 * 60 * 60

  @doc """
  Issue a fresh 6-digit code for an email and return `{plaintext_code, register}`.

  Caller is responsible for sending the plaintext code via email — the worker
  enqueue happens upstream.
  """
  @spec issue_code(String.t(), keyword()) ::
          {:ok, String.t(), AppRegister.t()}
          | {:error, :too_many_attempts | Ecto.Changeset.t()}
  def issue_code(email, opts \\ []) when is_binary(email) do
    email = String.downcase(email)
    code = generate_code()
    hash = hash_code(code)

    attrs = %{
      email: email,
      verify_code_hash: hash,
      ip: opts[:ip],
      email_delivered_at: DateTime.utc_now()
    }

    case Repo.get_by(AppRegister, email: email) do
      nil ->
        with {:ok, register} <- attrs |> AppRegister.insert_changeset() |> Repo.insert() do
          {:ok, code, register}
        end

      %AppRegister{uses: u} when u > @code_max_attempts ->
        {:error, :too_many_attempts}

      register ->
        register
        |> AppRegister.resend_changeset(%{
          verify_code_hash: hash,
          uses: register.uses + 1,
          email_delivered_at: attrs.email_delivered_at
        })
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, code, updated}
          err -> err
        end
    end
  end

  @doc """
  Check that a `(email, code)` pair matches an active registration.

  Does **not** delete or mutate the registration row — onboarding does that.
  Mirrors Pixelfed's `verifyCode`.
  """
  @spec verify_code(String.t(), String.t()) :: :ok | :error
  def verify_code(email, code) when is_binary(email) and is_binary(code) do
    email = String.downcase(email)
    expected_hash = hash_code(code)
    cutoff = DateTime.add(DateTime.utc_now(), -@code_ttl_seconds, :second)

    case Repo.get_by(AppRegister, email: email) do
      %AppRegister{} = register ->
        cond do
          DateTime.compare(register.inserted_at, cutoff) != :gt -> :error
          not Plug.Crypto.secure_compare(expected_hash, register.verify_code_hash) -> :error
          true -> :ok
        end

      _ ->
        # Run a fake comparison so timing doesn't leak whether the email exists.
        Plug.Crypto.secure_compare(expected_hash, expected_hash)
        :error
    end
  end

  @doc "Get the active registration row for an email (for tests / mix tasks)."
  @spec get_register(String.t()) :: AppRegister.t() | nil
  def get_register(email) when is_binary(email) do
    Repo.get_by(AppRegister, email: String.downcase(email))
  end

  @doc "Delete the registration after successful onboarding."
  @spec consume!(String.t()) :: :ok
  def consume!(email) when is_binary(email) do
    Repo.delete_all(from r in AppRegister, where: r.email == ^String.downcase(email))
    :ok
  end

  ## Internals

  defp generate_code do
    :crypto.strong_rand_bytes(4)
    |> :binary.decode_unsigned()
    |> rem(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  defp hash_code(code), do: :crypto.hash(:sha256, code)
end
