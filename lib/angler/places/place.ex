defmodule Angler.Places.Place do
  @moduledoc "A geotagged location that statuses can attach to."

  use Ecto.Schema
  import Ecto.Changeset

  schema "places" do
    field :name, :string
    field :slug, :string
    field :country, :string
    field :lat, :float
    field :long, :float
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(p \\ %__MODULE__{}, attrs) do
    p
    |> cast(attrs, [:name, :slug, :country, :lat, :long])
    |> validate_required([:name, :slug])
    |> update_change(:slug, &String.downcase/1)
    |> unique_constraint(:slug)
  end
end
