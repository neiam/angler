defmodule Angler.Federation.HttpSignatureKey do
  @moduledoc """
  Cached public keys for inbound HTTP signature verification.

  Refreshed on signature failure (key rotation case) and lazily after a week.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "http_signature_keys" do
    field :key_id, :string
    field :owner_url, :string
    field :public_key_pem, :string
    field :fetched_at, :utc_datetime_usec
    field :rotated_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(key, attrs) do
    key
    |> cast(attrs, [:key_id, :owner_url, :public_key_pem, :fetched_at, :rotated_at])
    |> validate_required([:key_id, :owner_url, :public_key_pem, :fetched_at])
    |> unique_constraint(:key_id)
  end
end
