defmodule Angler.Statuses.StatusHashtag do
  @moduledoc "Edge linking a status to a hashtag."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "status_hashtags" do
    belongs_to :status, Angler.Statuses.Status, type: :integer
    belongs_to :hashtag, Angler.Hashtags.Hashtag

    field :profile_id, :integer
    field :status_visibility, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(sh \\ %__MODULE__{}, attrs) do
    sh
    |> cast(attrs, [:status_id, :hashtag_id, :profile_id, :status_visibility])
    |> validate_required([:status_id, :hashtag_id, :profile_id, :status_visibility])
    |> unique_constraint([:status_id, :hashtag_id])
  end
end
