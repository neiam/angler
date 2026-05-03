defmodule Angler.Polls.Option do
  @moduledoc "An ordered choice within a poll."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Polls.Poll

  @primary_key {:id, :integer, autogenerate: false}
  schema "poll_options" do
    field :position, :integer
    field :title, :string
    field :votes_count, :integer, default: 0

    belongs_to :poll, Poll, type: :integer
  end

  def changeset(option \\ %__MODULE__{}, attrs) do
    option
    |> maybe_assign_id()
    |> cast(attrs, [:poll_id, :position, :title, :votes_count])
    |> validate_required([:poll_id, :position, :title])
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = o), do: %{o | id: Angler.Snowflake.next()}
  defp maybe_assign_id(o), do: o
end
