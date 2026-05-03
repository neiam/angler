defmodule Angler.Push.Subscription do
  @moduledoc """
  WebPush subscription bound to a single `oauth_tokens` row.

  We persist the endpoint + key material so a delivery worker can sign
  WebPush envelopes when we wire it up. The actual push pipeline isn't
  built yet — clients call this endpoint anyway during bootstrap, so we
  store the rows and respond with the standard envelope.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.OAuth.Token

  schema "push_subscriptions" do
    field :endpoint, :string
    field :p256dh, :string
    field :auth, :string, redact: true
    field :alerts, :map, default: %{}
    field :policy, :string, default: "all"
    belongs_to :token, Token, type: :integer
    timestamps(type: :utc_datetime_usec)
  end

  @policies ~w(all followed follower none)

  def changeset(sub \\ %__MODULE__{}, attrs) do
    sub
    |> cast(attrs, [:token_id, :endpoint, :p256dh, :auth, :alerts, :policy])
    |> validate_required([:token_id, :endpoint, :p256dh, :auth])
    |> validate_inclusion(:policy, @policies)
    |> unique_constraint(:token_id)
  end

  def policies, do: @policies
end
