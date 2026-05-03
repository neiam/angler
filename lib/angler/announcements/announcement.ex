defmodule Angler.Announcements.Announcement do
  @moduledoc "Operator-written announcement."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "announcements" do
    field :text, :string
    field :published, :boolean, default: false
    field :all_day, :boolean, default: false
    field :starts_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :published_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(a \\ %__MODULE__{}, attrs) do
    a
    |> maybe_assign_id()
    |> cast(attrs, [:text, :published, :all_day, :starts_at, :ends_at, :published_at])
    |> validate_required([:text])
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = a), do: %{a | id: Angler.Snowflake.next()}
  defp maybe_assign_id(a), do: a
end

defmodule Angler.Announcements.Dismissal do
  @moduledoc "Per-user dismissal of an announcement."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Announcements.Announcement
  alias Angler.Profiles.Profile

  schema "announcement_dismissals" do
    belongs_to :announcement, Announcement, type: :integer
    belongs_to :profile, Profile, type: :integer
    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
  end

  def changeset(d \\ %__MODULE__{}, attrs) do
    d
    |> cast(attrs, [:announcement_id, :profile_id])
    |> validate_required([:announcement_id, :profile_id])
    |> unique_constraint([:announcement_id, :profile_id])
  end
end
