defmodule Angler.CuratedRegistrations.Template do
  @moduledoc """
  A canned reply admins can drop into a curated-registration review message
  (upstream CuratedRegisterTemplate). Only active ones are offered.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "curated_register_templates" do
    field :name, :string
    field :description, :string
    field :content, :string
    field :is_active, :boolean, default: false
    field :order, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(template \\ %__MODULE__{}, attrs) do
    template
    |> cast(attrs, [:name, :description, :content, :is_active, :order])
    |> validate_required([:name, :content])
    |> validate_length(:name, max: 30)
    |> validate_length(:content, min: 5, max: 3000)
    |> validate_length(:description, max: 1000)
  end
end
