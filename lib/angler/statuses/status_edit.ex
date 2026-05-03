defmodule Angler.Statuses.StatusEdit do
  @moduledoc """
  One row per historical revision of a status. Captured before each `update_local`
  applies, so the live `Status` row always represents the latest version.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Statuses.Status

  schema "status_edits" do
    field :caption, :string
    field :rendered, :string
    field :spoiler_text, :string
    field :is_nsfw, :boolean, default: false
    field :media_attachments, :map, default: %{}
    field :poll, :map
    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}

    belongs_to :status, Status, type: :integer
  end

  def changeset(edit \\ %__MODULE__{}, attrs) do
    edit
    |> cast(attrs, [
      :status_id,
      :caption,
      :rendered,
      :spoiler_text,
      :is_nsfw,
      :media_attachments,
      :poll,
      :inserted_at
    ])
    |> validate_required([:status_id, :caption, :rendered])
  end
end
