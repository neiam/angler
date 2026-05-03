defmodule Angler.Polls.Poll do
  @moduledoc "Poll attached to a status. Single-choice unless `multiple: true`."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Polls.Option
  alias Angler.Statuses.Status

  @primary_key {:id, :integer, autogenerate: false}
  schema "polls" do
    field :expires_at, :utc_datetime_usec
    field :multiple, :boolean, default: false
    field :hide_totals, :boolean, default: false
    field :voters_count, :integer, default: 0

    belongs_to :status, Status, type: :integer
    has_many :options, Option, preload_order: [asc: :position]

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(poll \\ %__MODULE__{}, attrs) do
    poll
    |> maybe_assign_id()
    |> cast(attrs, [:status_id, :expires_at, :multiple, :hide_totals, :voters_count])
    |> validate_required([:status_id, :expires_at])
    |> unique_constraint(:status_id)
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = p), do: %{p | id: Angler.Snowflake.next()}
  defp maybe_assign_id(p), do: p
end
