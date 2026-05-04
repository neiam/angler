defmodule Angler.Statuses.ArchivedSnapshot do
  @moduledoc "Captures the original `scope` of a status when it's archived."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Statuses.Status

  @primary_key false
  schema "status_archived_snapshots" do
    belongs_to :status, Status, type: :integer, primary_key: true
    field :original_scope, :string
    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
  end

  def changeset(s \\ %__MODULE__{}, attrs) do
    s
    |> cast(attrs, [:status_id, :original_scope])
    |> validate_required([:status_id, :original_scope])
  end
end
