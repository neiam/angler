defmodule Angler.Filters.Keyword do
  @moduledoc "One keyword inside a filter."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Filters.Filter

  @primary_key {:id, :integer, autogenerate: false}
  schema "filter_keywords" do
    field :keyword, :string
    field :whole_word, :boolean, default: false
    belongs_to :filter, Filter, type: :integer
  end

  def changeset(kw \\ %__MODULE__{}, attrs) do
    kw
    |> maybe_assign_id()
    |> cast(attrs, [:filter_id, :keyword, :whole_word])
    |> validate_required([:filter_id, :keyword])
    |> validate_length(:keyword, min: 1, max: 200)
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = k), do: %{k | id: Angler.Snowflake.next()}
  defp maybe_assign_id(k), do: k
end
