defmodule Angler.Invites.AdminInvite do
  @moduledoc """
  An admin-issued signup invitation. The mobile app's pre-registration
  endpoints (`auth/invite/admin/{verify,uc,ec}`) check these to gate
  registration on closed instances.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Accounts.User

  @type t :: %__MODULE__{}

  schema "admin_invites" do
    field :invite_code, :string
    field :message, :string
    field :max_uses, :integer
    field :uses, :integer, default: 0
    field :expires_at, :utc_datetime_usec
    field :skip_email_verification, :boolean, default: false

    belongs_to :created_by_user, User, foreign_key: :created_by_user_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(invite \\ %__MODULE__{}, attrs) do
    invite
    |> cast(attrs, [
      :id,
      :invite_code,
      :message,
      :max_uses,
      :uses,
      :expires_at,
      :skip_email_verification,
      :created_by_user_id
    ])
    |> validate_required([:invite_code])
    |> unique_constraint(:invite_code)
  end
end
