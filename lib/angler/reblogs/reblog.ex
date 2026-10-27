defmodule Angler.Reblogs.Reblog do
  @moduledoc "An `Announce` / share / boost / reblog of a status."

  use Ecto.Schema
  import Ecto.Changeset

  schema "reblogs" do
    belongs_to :profile, Angler.Profiles.Profile, type: :integer
    belongs_to :status, Angler.Statuses.Status, type: :integer
    # The id of this boost's wrapper status in timelines — a snowflake of
    # its own, not a `statuses` row (`AnglerWeb.MastodonAPI.Status`).
    field :reblog_status_id, :integer
    field :remote_url, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(reblog \\ %__MODULE__{}, attrs) do
    reblog
    |> cast(attrs, [:profile_id, :status_id, :reblog_status_id, :remote_url])
    |> put_wrapper_id()
    |> validate_required([:profile_id, :status_id])
    |> unique_constraint([:profile_id, :status_id])
    |> unique_constraint(:remote_url)
  end

  defp put_wrapper_id(changeset) do
    case get_field(changeset, :reblog_status_id) do
      nil -> put_change(changeset, :reblog_status_id, Angler.Snowflake.next())
      _ -> changeset
    end
  end
end
