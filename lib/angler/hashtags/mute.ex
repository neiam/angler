defmodule Angler.Hashtags.Mute do
  @moduledoc """
  Per-user hashtag mute. The inverse of `Angler.Hashtags.Follow`: a status
  carrying a muted tag is blurred, warned, or hidden in the muting user's feeds.
  `filter_action` mirrors the keyword-filter actions in `Angler.Filters.Filter`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Hashtags.Hashtag
  alias Angler.Profiles.Profile

  @actions ~w(blur warn hide)

  schema "muted_tags" do
    belongs_to :profile, Profile, type: :integer
    belongs_to :hashtag, Hashtag
    field :filter_action, :string, default: "hide"
    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
  end

  def changeset(mute \\ %__MODULE__{}, attrs) do
    mute
    |> cast(attrs, [:profile_id, :hashtag_id, :filter_action])
    |> validate_required([:profile_id, :hashtag_id, :filter_action])
    |> validate_inclusion(:filter_action, @actions)
    |> unique_constraint([:profile_id, :hashtag_id])
  end

  def actions, do: @actions
end
