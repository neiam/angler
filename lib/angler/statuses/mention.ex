defmodule Angler.Statuses.Mention do
  @moduledoc "An `@user` mention inside a status."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "mentions" do
    belongs_to :status, Angler.Statuses.Status, type: :integer
    belongs_to :profile, Angler.Profiles.Profile, type: :integer
    field :silent, :boolean, default: false

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(mention \\ %__MODULE__{}, attrs) do
    mention
    |> cast(attrs, [:status_id, :profile_id, :silent])
    |> validate_required([:status_id, :profile_id])
    |> unique_constraint([:status_id, :profile_id])
  end
end
