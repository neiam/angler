defmodule Angler.Notifications.Notification do
  @moduledoc """
  Per-recipient notification produced by an interaction (favourite, reblog,
  follow, mention, …).

  Notifications are local-only — never federated. The `account_id` is the
  actor whose action triggered the notification (e.g., the favouriter). The
  `status_id` is the relevant status, when one applies (mention/favourite/
  reblog), or NULL (follow/follow_request).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Profiles.Profile
  alias Angler.Statuses.Status

  @types ~w(mention favourite reblog follow follow_request status update poll)

  @type t :: %__MODULE__{}

  schema "notifications" do
    field :type, :string
    field :dismissed, :boolean, default: false

    belongs_to :recipient, Profile, type: :integer
    belongs_to :account, Profile, type: :integer
    belongs_to :status, Status, type: :integer

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(notification \\ %__MODULE__{}, attrs) do
    notification
    |> cast(attrs, [:recipient_id, :account_id, :type, :status_id, :dismissed])
    |> validate_required([:recipient_id, :account_id, :type])
    |> validate_inclusion(:type, @types)
    |> foreign_key_constraint(:recipient_id)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:status_id)
  end

  def types, do: @types
end
