defmodule Angler.Follows.Follower do
  @moduledoc """
  A follow edge.

  `profile_id` = the followee, `following_id` = the follower. Pixelfed's
  column names; "the follower follows the followee".
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "followers" do
    belongs_to :profile, Angler.Profiles.Profile
    belongs_to :following, Angler.Profiles.Profile

    field :show_reblogs, :boolean, default: true
    field :notify, :boolean, default: false
    field :languages, {:array, :string}, default: []
    field :pending_remote, :boolean, default: false
    field :remote_url, :string
    field :accepted_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(follower \\ %__MODULE__{}, attrs) do
    follower
    |> cast(attrs, [
      :profile_id,
      :following_id,
      :show_reblogs,
      :notify,
      :languages,
      :pending_remote,
      :remote_url,
      :accepted_at
    ])
    |> validate_required([:profile_id, :following_id])
    |> unique_constraint([:profile_id, :following_id])
    |> unique_constraint(:remote_url)
  end
end
