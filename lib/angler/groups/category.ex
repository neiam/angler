defmodule Angler.Groups.Category do
  @moduledoc "Lookup row for grouping `Group` rows under a category in the UI."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "group_categories" do
    field :name, :string
    field :slug, :string
    field :order, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(cat \\ %__MODULE__{}, attrs) do
    cat
    |> maybe_assign_id()
    |> cast(attrs, [:id, :name, :slug, :order])
    |> validate_required([:name, :slug])
    |> update_change(:slug, &String.downcase/1)
    |> unique_constraint(:slug)
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = c), do: %{c | id: Angler.Snowflake.next()}
  defp maybe_assign_id(c), do: c
end
