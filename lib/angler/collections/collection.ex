defmodule Angler.Collections.Collection do
  @moduledoc "Pixelfed photo collection (curated photo album)."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Profiles.Profile

  @visibilities ~w(public private draft)

  @primary_key {:id, :integer, autogenerate: false}
  schema "collections" do
    field :title, :string
    field :description, :string
    field :visibility, :string, default: "draft"
    field :published_at, :utc_datetime_usec
    belongs_to :profile, Profile, type: :integer
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(c \\ %__MODULE__{}, attrs) do
    c
    |> maybe_assign_id()
    |> cast(attrs, [:profile_id, :title, :description, :visibility, :published_at])
    |> validate_required([:profile_id])
    |> validate_inclusion(:visibility, @visibilities)
    |> validate_length(:title, max: 50)
    |> validate_length(:description, max: 500)
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = c), do: %{c | id: Angler.Snowflake.next()}
  defp maybe_assign_id(c), do: c

  def visibilities, do: @visibilities
end
