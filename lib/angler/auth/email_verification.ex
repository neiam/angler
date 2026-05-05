defmodule Angler.Auth.EmailVerification do
  @moduledoc """
  In-flight email verification for the in-app registration handshake.
  Created by `POST /api/v1.1/auth/iar`, consumed by `POST /api/v1.1/auth/iarc`.
  Expires after 24h.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Accounts.User

  schema "email_verifications" do
    field :email, :string
    field :user_token, :string
    field :random_token, :string
    belongs_to :user, User, type: :integer
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(v \\ %__MODULE__{}, attrs) do
    v
    |> cast(attrs, [:user_id, :email, :user_token, :random_token])
    |> validate_required([:user_id, :email, :user_token, :random_token])
    |> unique_constraint(:user_token)
    |> unique_constraint(:random_token)
  end

  @doc "Whether the row was created within the last 24 hours."
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{inserted_at: %DateTime{} = inserted}) do
    DateTime.diff(DateTime.utc_now(), inserted, :second) < 24 * 60 * 60
  end

  def valid?(_), do: false

  @type t :: %__MODULE__{}
end
