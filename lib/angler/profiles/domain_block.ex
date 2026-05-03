defmodule Angler.Profiles.DomainBlock do
  @moduledoc "User-level domain mute. Hides every account/status from `domain`."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Profiles.Profile

  schema "user_domain_blocks" do
    belongs_to :profile, Profile, type: :integer
    field :domain, :string
    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
  end

  def changeset(b \\ %__MODULE__{}, attrs) do
    b
    |> cast(attrs, [:profile_id, :domain])
    |> validate_required([:profile_id, :domain])
    |> update_change(:domain, &String.downcase/1)
    |> unique_constraint([:profile_id, :domain])
  end
end
