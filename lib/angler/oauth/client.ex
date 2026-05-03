defmodule Angler.OAuth.Client do
  @moduledoc "Registered OAuth 2.0 client application."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "oauth_clients" do
    field :name, :string
    field :secret_hash, :binary, redact: true
    field :redirect_uris, {:array, :string}, default: []
    field :scopes, {:array, :string}, default: ["read"]
    field :website, :string
    field :owner_user_id, :id
    field :revoked, :boolean, default: false
    field :first_party, :boolean, default: false
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(client, attrs) do
    client
    |> maybe_assign_id()
    |> cast(attrs, [
      :name,
      :secret_hash,
      :redirect_uris,
      :scopes,
      :website,
      :owner_user_id,
      :revoked,
      :first_party
    ])
    |> validate_required([:name, :secret_hash])
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = c), do: %{c | id: Angler.Snowflake.next()}
  defp maybe_assign_id(c), do: c
end
