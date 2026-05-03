defmodule Angler.Likes.Like do
  @moduledoc "A favourite (Mastodon) / like (Pixelfed) on a status."

  use Ecto.Schema
  import Ecto.Changeset

  schema "likes" do
    belongs_to :profile, Angler.Profiles.Profile, type: :integer
    belongs_to :status, Angler.Statuses.Status, type: :integer
    field :remote_url, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(like \\ %__MODULE__{}, attrs) do
    like
    |> cast(attrs, [:profile_id, :status_id, :remote_url])
    |> validate_required([:profile_id, :status_id])
    |> unique_constraint([:profile_id, :status_id])
    |> unique_constraint(:remote_url)
  end
end
