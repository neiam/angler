defmodule Angler.Lists.ListAccount do
  @moduledoc "Membership row: profile X is in list Y."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Lists.List
  alias Angler.Profiles.Profile

  schema "list_accounts" do
    belongs_to :list, List, type: :integer
    belongs_to :profile, Profile, type: :integer
    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
  end

  def changeset(la \\ %__MODULE__{}, attrs) do
    la
    |> cast(attrs, [:list_id, :profile_id])
    |> validate_required([:list_id, :profile_id])
    |> unique_constraint([:list_id, :profile_id])
  end
end
