defmodule Angler.Accounts.User do
  @moduledoc """
  Local user (auth identity).

  Federated profiles are headless — they have no `User`. Local users always
  have an associated `Angler.Profiles.Profile`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Profiles.Profile

  schema "users" do
    field :email, :string
    field :email_verified_at, :utc_datetime_usec

    field :password_hash, :string
    # Virtual on the changeset; never persisted, never returned.
    field :password, :string, virtual: true, redact: true

    field :name, :string
    field :language, :string, default: "en"
    field :timezone, :string, default: "UTC"
    field :is_admin, :boolean, default: false
    field :is_moderator, :boolean, default: false
    field :status, :string

    field :last_active_at, :utc_datetime_usec

    field :two_factor_secret_enc, :binary, redact: true
    field :two_factor_recovery_enc, :binary, redact: true
    field :two_factor_enabled_at, :utc_datetime_usec

    field :register_source, :string
    field :register_ip, :string

    # Pixelfed Expo push subscription (mobile FCM/APNs via Expo gateway).
    # Stored on the user, not a token, since clients use this to drive
    # outbound mobile notifications regardless of which OAuth token issued.
    field :expo_token, :string
    field :notify_enabled, :boolean, default: false
    field :notify_like, :boolean, default: false
    field :notify_follow, :boolean, default: false
    field :notify_mention, :boolean, default: false
    field :notify_comment, :boolean, default: false

    belongs_to :profile, Profile

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating a user via the in-app registration flow.

  Hashes `:password` into `:password_hash` via Argon2 if a password was provided.
  """
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :email,
      :name,
      :password,
      :register_source,
      :register_ip,
      :profile_id,
      :email_verified_at
    ])
    |> validate_required([:email, :password, :profile_id])
    |> validate_email()
    |> validate_password()
    |> hash_password()
    |> unique_constraint(:email)
    |> unique_constraint(:profile_id)
  end

  defp validate_email(changeset) do
    changeset
    |> update_change(:email, fn
      nil -> nil
      email -> String.downcase(email)
    end)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+$/, message: "is invalid")
    |> validate_length(:email, max: 254)
  end

  defp validate_password(changeset) do
    changeset
    |> validate_length(:password, min: 8, max: 128)
    # Light-touch strength check; refuse only the trivial inputs. Real strength
    # rules belong in admin-configurable policy.
    |> validate_change(:password, fn :password, pw ->
      if pw == String.duplicate(String.first(pw) || "", String.length(pw)) do
        [password: "is too weak"]
      else
        []
      end
    end)
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      pw ->
        changeset
        |> put_change(:password_hash, Argon2.hash_pwd_salt(pw))
        |> delete_change(:password)
    end
  end

  @doc """
  Changeset for `POST /api/v1.1/accounts/change-password`. Validates the
  candidate `password` shape and hashes it; the controller is responsible
  for verifying the *current* password before invoking this.
  """
  def change_password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_password()
    |> hash_password()
  end

  @doc "Constant-time check of a candidate password against a user's stored hash."
  def valid_password?(%__MODULE__{password_hash: hash}, password)
      when is_binary(hash) and is_binary(password) and byte_size(password) > 0 do
    Argon2.verify_pass(password, hash)
  end

  def valid_password?(_user, _password) do
    Argon2.no_user_verify()
    false
  end
end
