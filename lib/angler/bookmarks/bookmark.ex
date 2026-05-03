defmodule Angler.Bookmarks.Bookmark do
  @moduledoc "Personal saved-for-later marker on a status. Local-only — no federation."

  use Ecto.Schema
  import Ecto.Changeset

  schema "bookmarks" do
    belongs_to :profile, Angler.Profiles.Profile, type: :integer
    belongs_to :status, Angler.Statuses.Status, type: :integer
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(bookmark \\ %__MODULE__{}, attrs) do
    bookmark
    |> cast(attrs, [:profile_id, :status_id])
    |> validate_required([:profile_id, :status_id])
    |> unique_constraint([:profile_id, :status_id])
  end
end
