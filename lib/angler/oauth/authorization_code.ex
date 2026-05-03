defmodule Angler.OAuth.AuthorizationCode do
  @moduledoc """
  Short-lived authorization code for the `authorization_code` grant.

  Stored as `:bytea` (SHA-256 of the raw code). The raw value is returned
  to the caller exactly once at issuance and then handed to the user-agent
  via the redirect_uri query string.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Accounts.User
  alias Angler.OAuth.Client

  schema "oauth_authorization_codes" do
    field :code_hash, :binary, redact: true
    field :scopes, {:array, :string}, default: []
    field :redirect_uri, :string
    field :code_challenge, :string
    field :code_challenge_method, :string
    field :expires_at, :utc_datetime_usec
    field :redeemed_at, :utc_datetime_usec

    belongs_to :client, Client, type: :integer
    belongs_to :user, User, type: :integer

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(code \\ %__MODULE__{}, attrs) do
    code
    |> cast(attrs, [
      :code_hash,
      :client_id,
      :user_id,
      :scopes,
      :redirect_uri,
      :code_challenge,
      :code_challenge_method,
      :expires_at,
      :redeemed_at
    ])
    |> validate_required([:code_hash, :client_id, :user_id, :redirect_uri, :expires_at])
    |> validate_inclusion(:code_challenge_method, [nil, "S256", "plain"])
    |> unique_constraint(:code_hash)
    |> foreign_key_constraint(:client_id)
    |> foreign_key_constraint(:user_id)
  end
end
