defmodule Angler.Stories.Story do
  @moduledoc "Ephemeral 24h media owned by a single profile."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Profiles.Profile

  @types ~w(photo video)

  @primary_key {:id, :integer, autogenerate: false}
  schema "stories" do
    field :type, :string
    field :mime, :string
    field :path, :string
    field :duration_ms, :integer, default: 3_000
    field :can_reply, :boolean, default: true
    field :can_react, :boolean, default: true
    field :active, :boolean, default: false
    field :view_count, :integer, default: 0
    field :local, :boolean, default: true
    field :remote_url, :string
    field :expires_at, :utc_datetime_usec

    belongs_to :profile, Profile, type: :integer
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(story \\ %__MODULE__{}, attrs) do
    story
    |> maybe_assign_id()
    |> cast(attrs, [
      :profile_id,
      :type,
      :mime,
      :path,
      :duration_ms,
      :can_reply,
      :can_react,
      :active,
      :view_count,
      :local,
      :remote_url,
      :expires_at
    ])
    |> validate_required([:profile_id, :type, :mime, :path, :expires_at])
    |> validate_inclusion(:type, @types)
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = s), do: %{s | id: Angler.Snowflake.next()}
  defp maybe_assign_id(s), do: s

  def types, do: @types
end
