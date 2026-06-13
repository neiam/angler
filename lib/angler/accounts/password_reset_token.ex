defmodule Angler.Accounts.PasswordResetToken do
  @moduledoc """
  One-time, hashed password-reset token (magic-link style).

  The random token is generated, its SHA-256 hash stored here, and the
  plaintext handed to the emailed reset URL. Verification re-hashes the
  presented token and looks it up; rows older than the validity window are
  ignored and swept.
  """

  use Ecto.Schema

  alias Angler.Accounts.User

  schema "password_reset_tokens" do
    field :token, :binary, redact: true
    belongs_to :user, User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
