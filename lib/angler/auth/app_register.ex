defmodule Angler.Auth.AppRegister do
  @moduledoc """
  In-flight in-app registrations: an email address that's been issued a
  6-digit verification code but hasn't completed onboarding yet.

  Code is stored as a SHA-256 hash; the plaintext is only ever in memory long
  enough to send the email. Verification is constant-time.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "app_registers" do
    field :email, :string
    field :verify_code_hash, :binary, redact: true
    field :verify_code_attempts, :integer, default: 0
    field :uses, :integer, default: 1
    field :email_delivered_at, :utc_datetime_usec
    field :ip, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:email, :verify_code_hash, :uses, :email_delivered_at, :ip])
    |> validate_required([:email, :verify_code_hash])
    |> update_change(:email, &String.downcase/1)
    |> unique_constraint(:email)
  end

  @doc false
  def resend_changeset(register, attrs) do
    register
    |> cast(attrs, [:verify_code_hash, :uses, :email_delivered_at])
    |> validate_required([:verify_code_hash])
  end
end
