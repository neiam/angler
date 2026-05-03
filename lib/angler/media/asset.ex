defmodule Angler.Media.Asset do
  @moduledoc """
  Primary attachment row. Created in `:pending` state by an upload, transitioned
  to `:ready` (or `:failed`) by the processing worker.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Profiles.Profile
  alias Angler.Statuses.Status

  @type t :: %__MODULE__{}

  @primary_key {:id, :integer, []}
  schema "media" do
    field :media_type, :string
    field :sha256, :binary
    field :size_bytes, :integer
    field :width, :integer
    field :height, :integer
    field :duration_ms, :integer
    field :blurhash, :string

    field :caption, :string
    field :license, :string

    field :remote_url, :string
    field :path_original, :string
    field :path_thumb, :string
    field :path_preview, :string
    field :storage, :string, default: "local"
    field :status, :string, default: "pending"

    field :metadata, :map, default: %{}
    field :unattached_at, :utc_datetime_usec

    belongs_to :profile, Profile, type: :integer
    belongs_to :attached_status, Status, foreign_key: :status_id, type: :integer

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(asset \\ %__MODULE__{}, attrs) do
    asset
    |> cast(attrs, [
      :id,
      :profile_id,
      :status_id,
      :media_type,
      :sha256,
      :size_bytes,
      :width,
      :height,
      :duration_ms,
      :blurhash,
      :caption,
      :license,
      :remote_url,
      :path_original,
      :path_thumb,
      :path_preview,
      :storage,
      :status,
      :metadata,
      :unattached_at
    ])
    |> validate_required([:profile_id, :media_type, :storage, :status])
    |> maybe_assign_id()
    |> validate_inclusion(:status, ~w(pending ready failed deleted))
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:status_id)
    |> unique_constraint([:sha256, :profile_id], name: :media_sha256_profile_id_index)
  end

  defp maybe_assign_id(cs) do
    case get_field(cs, :id) do
      nil -> put_change(cs, :id, Angler.Snowflake.next())
      _ -> cs
    end
  end
end
