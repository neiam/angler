defmodule Angler.Lists.List do
  @moduledoc "User-curated subset of accounts for the `/timelines/list/:id` feed."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Profiles.Profile

  @replies_policies ~w(followed list none)

  @primary_key {:id, :integer, autogenerate: false}
  schema "lists" do
    field :title, :string
    field :replies_policy, :string, default: "list"
    field :exclusive, :boolean, default: false
    belongs_to :profile, Profile, type: :integer
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(list \\ %__MODULE__{}, attrs) do
    list
    |> maybe_assign_id()
    |> cast(attrs, [:profile_id, :title, :replies_policy, :exclusive])
    |> validate_required([:profile_id, :title])
    |> validate_length(:title, min: 1, max: 100)
    |> validate_inclusion(:replies_policy, @replies_policies)
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = l), do: %{l | id: Angler.Snowflake.next()}
  defp maybe_assign_id(l), do: l

  def replies_policies, do: @replies_policies
end
