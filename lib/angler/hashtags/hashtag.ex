defmodule Angler.Hashtags.Hashtag do
  @moduledoc "A hashtag (case-insensitive name + slug)."

  use Ecto.Schema
  import Ecto.Changeset

  schema "hashtags" do
    field :name, :string
    field :slug, :string
    field :usage_count, :integer, default: 0
    field :disabled, :boolean, default: false
    field :nsfw, :boolean, default: false
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(tag \\ %__MODULE__{}, attrs) do
    tag
    |> cast(attrs, [:name, :slug, :usage_count, :disabled, :nsfw])
    |> validate_required([:name, :slug])
    |> update_change(:name, &String.downcase/1)
    |> update_change(:slug, &String.downcase/1)
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
  end
end
