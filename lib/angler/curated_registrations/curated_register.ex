defmodule Angler.CuratedRegistrations.CuratedRegister do
  @moduledoc """
  A curated-registration application (upstream `App\\Models\\CuratedRegister`):
  the requested username and email, the already-hashed password, and why the
  applicant wants to join. Approval turns it into a real account; until then
  nothing exists in `users` or `profiles`.

  The email confirmation code is stored only as a SHA-256 hash.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Accounts.User
  alias Angler.CuratedRegistrations.Activity

  schema "curated_registers" do
    field :email, :string
    field :username, :string
    field :password_hash, :string, redact: true
    field :ip_address, :string
    field :verify_code_hash, :binary, redact: true
    field :reason_to_join, :string
    field :is_approved, :boolean, default: false
    field :is_rejected, :boolean, default: false
    field :is_awaiting_more_info, :boolean, default: false
    field :user_has_responded, :boolean, default: false
    field :is_closed, :boolean, default: false
    field :email_verified_at, :utc_datetime_usec
    field :action_taken_at, :utc_datetime_usec
    field :code_sent_at, :utc_datetime_usec

    field :password, :string, virtual: true, redact: true
    field :password_confirmation, :string, virtual: true, redact: true
    field :agree, :boolean, virtual: true

    belongs_to :approved_by_admin, User
    has_many :activities, Activity, foreign_key: :register_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc """
  Shape checks for a new application (upstream `stepTwo` rules). Uniqueness
  against users, profiles and other open applications is checked by
  `Angler.CuratedRegistrations.submit/2`, which also hashes the password.
  """
  def submit_changeset(register \\ %__MODULE__{}, attrs) do
    register
    |> cast(attrs, [:username, :email, :password, :password_confirmation, :reason_to_join, :agree])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> update_change(:username, &String.trim/1)
    |> validate_required([:username, :email, :password, :password_confirmation, :reason_to_join])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+$/, message: "is invalid")
    |> validate_length(:email, max: 254)
    |> validate_length(:reason_to_join, min: 20, max: 1000)
    |> validate_confirmation(:password, required: true, message: "does not match")
    |> validate_acceptance(:agree, message: "you must agree to the rules and terms")
    |> unique_constraint(:email, name: :curated_registers_open_email_index)
    |> unique_constraint(:username, name: :curated_registers_open_username_index)
  end

  @doc "Status label for the admin queue, in upstream `adminStatusLabel()` order."
  @spec status(t()) :: atom()
  def status(%__MODULE__{} = r) do
    cond do
      r.user_has_responded and not r.is_closed -> :awaiting_admin
      is_nil(r.email_verified_at) -> :unverified
      r.is_approved -> :approved
      r.is_rejected -> :rejected
      r.is_awaiting_more_info -> :awaiting_user
      r.is_closed -> :closed
      true -> :open
    end
  end
end
