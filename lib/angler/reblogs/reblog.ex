defmodule Angler.Reblogs.Reblog do
  @moduledoc "An `Announce` / share / boost / reblog of a status."

  use Ecto.Schema
  import Ecto.Changeset

  schema "reblogs" do
    belongs_to :profile, Angler.Profiles.Profile, type: :integer
    belongs_to :status, Angler.Statuses.Status, type: :integer
    # Synthetic status row created so the reblog appears in feeds. Optional —
    # not used yet; will be filled in when feeds land.
    field :reblog_status_id, :integer
    field :remote_url, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(reblog \\ %__MODULE__{}, attrs) do
    reblog
    |> cast(attrs, [:profile_id, :status_id, :reblog_status_id, :remote_url])
    |> validate_required([:profile_id, :status_id])
    |> unique_constraint([:profile_id, :status_id])
    |> unique_constraint(:remote_url)
  end
end
