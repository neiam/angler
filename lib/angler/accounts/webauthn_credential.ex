defmodule Angler.Accounts.WebauthnCredential do
  @moduledoc "A registered WebAuthn/FIDO2 credential (security key or passkey)."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Accounts.User

  @type t :: %__MODULE__{}

  schema "webauthn_credentials" do
    field :credential_id, :binary
    field :public_key, :binary
    field :sign_count, :integer, default: 0
    field :aaguid, Ecto.UUID
    field :name, :string
    field :last_used_at, :utc_datetime

    belongs_to :user, User, type: :integer

    timestamps(type: :utc_datetime)
  end

  def create_changeset(struct, attrs) do
    struct
    |> cast(attrs, [:user_id, :credential_id, :public_key, :sign_count, :aaguid, :name])
    |> validate_required([:user_id, :credential_id, :public_key])
    |> validate_length(:name, max: 100)
    |> unique_constraint([:user_id, :credential_id],
      name: :webauthn_credentials_user_credential_index
    )
  end

  def usage_changeset(struct, new_sign_count) do
    change(struct, sign_count: new_sign_count, last_used_at: DateTime.utc_now(:second))
  end

  def rename_changeset(struct, name) do
    struct |> cast(%{name: name}, [:name]) |> validate_length(:name, max: 100)
  end
end
