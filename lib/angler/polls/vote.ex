defmodule Angler.Polls.Vote do
  @moduledoc "One vote a profile cast on a poll option."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Polls.{Option, Poll}
  alias Angler.Profiles.Profile

  @primary_key {:id, :integer, autogenerate: false}
  schema "poll_votes" do
    belongs_to :poll, Poll, type: :integer
    belongs_to :option, Option, type: :integer
    belongs_to :profile, Profile, type: :integer

    field :inserted_at, :utc_datetime_usec
  end

  def changeset(vote \\ %__MODULE__{}, attrs) do
    vote
    |> maybe_assign_id()
    |> cast(attrs, [:poll_id, :option_id, :profile_id, :inserted_at])
    |> validate_required([:poll_id, :option_id, :profile_id])
    |> unique_constraint([:poll_id, :profile_id, :option_id])
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = v), do: %{v | id: Angler.Snowflake.next()}
  defp maybe_assign_id(v), do: v
end
