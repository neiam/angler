defmodule Angler.Federation.Relay do
  @moduledoc """
  An ActivityPub relay subscription.

  LitePub/Pleroma model: the operator provides the relay's `actor_url`; we
  discover `inbox_url` from the actor doc and `Follow` the actor directly.

  Lifecycle: `:pending` (Follow sent, awaiting Accept) → `:accepted` (relay
  Accepted; its `Announce`s are now ingested) → `:idle` (disabled via Undo,
  kept so it can be re-enabled).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @states [:pending, :accepted, :idle]

  schema "relays" do
    field :inbox_url, :string
    field :actor_url, :string
    field :follow_activity_id, :string
    field :state, Ecto.Enum, values: @states, default: :pending
    timestamps(type: :utc_datetime_usec)
  end

  @doc "The valid state values."
  def states, do: @states

  @doc false
  def changeset(relay \\ %__MODULE__{}, attrs) do
    relay
    |> cast(attrs, [:actor_url, :inbox_url, :follow_activity_id, :state])
    |> validate_required([:actor_url, :inbox_url, :follow_activity_id])
    |> unique_constraint(:actor_url)
    |> unique_constraint(:follow_activity_id)
  end
end
