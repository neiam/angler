defmodule Angler.OAuth.Token do
  @moduledoc "Issued OAuth 2.0 access (and optional refresh) token."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "oauth_tokens" do
    field :token_hash, :binary, redact: true
    field :refresh_hash, :binary, redact: true
    field :client_id, :id
    field :user_id, :id
    field :profile_id, :id
    field :scopes, {:array, :string}
    field :expires_at, :utc_datetime_usec
    field :refresh_expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :ip, :string
    field :user_agent, :string
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(token, attrs) do
    token
    |> maybe_assign_id()
    |> cast(attrs, [
      :token_hash,
      :refresh_hash,
      :client_id,
      :user_id,
      :profile_id,
      :scopes,
      :expires_at,
      :refresh_expires_at,
      :last_used_at,
      :revoked_at,
      :ip,
      :user_agent
    ])
    |> validate_required([:token_hash, :client_id, :scopes])
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = t), do: %{t | id: Angler.Snowflake.next()}
  defp maybe_assign_id(t), do: t
end
