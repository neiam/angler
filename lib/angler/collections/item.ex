defmodule Angler.Collections.Item do
  @moduledoc "Status pinned into a collection at `position`."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Collections.Collection
  alias Angler.Statuses.Status

  schema "collection_items" do
    field :position, :integer, default: 0
    belongs_to :collection, Collection, type: :integer
    belongs_to :status, Status, type: :integer
    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
  end

  def changeset(item \\ %__MODULE__{}, attrs) do
    item
    |> cast(attrs, [:collection_id, :status_id, :position])
    |> validate_required([:collection_id, :status_id])
    |> unique_constraint([:collection_id, :status_id])
  end
end
