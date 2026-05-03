defmodule Angler.Follows.FollowRequest do
  @moduledoc "Pending follow when target is locked."

  use Ecto.Schema
  import Ecto.Changeset

  schema "follow_requests" do
    belongs_to :profile, Angler.Profiles.Profile
    belongs_to :following, Angler.Profiles.Profile
    field :remote_url, :string
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(req \\ %__MODULE__{}, attrs) do
    req
    |> cast(attrs, [:profile_id, :following_id, :remote_url])
    |> validate_required([:profile_id, :following_id])
    |> unique_constraint([:profile_id, :following_id])
  end
end
