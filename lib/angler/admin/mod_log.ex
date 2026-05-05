defmodule Angler.Admin.ModLog do
  @moduledoc """
  Audit row written by `Angler.Admin` whenever a moderator/admin takes a
  privileged action. Mirrors Pixelfed's ModLogService — append-only,
  read by the admin tooling.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Accounts.User

  @primary_key {:id, :integer, autogenerate: false}
  schema "mod_logs" do
    field :object_type, :string
    field :object_id, :integer
    field :object_uid, :integer
    field :action, :string
    field :access_level, :string, default: "moderator"
    field :metadata, :map, default: %{}

    belongs_to :actor_user, User, type: :integer

    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
  end

  def changeset(log \\ %__MODULE__{}, attrs) do
    log
    |> maybe_assign_id()
    |> cast(attrs, [
      :actor_user_id,
      :object_type,
      :object_id,
      :object_uid,
      :action,
      :access_level,
      :metadata
    ])
    |> validate_required([:actor_user_id, :object_type, :action])
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = l), do: %{l | id: Angler.Snowflake.next()}
  defp maybe_assign_id(l), do: l
end
