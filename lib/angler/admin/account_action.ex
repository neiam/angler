defmodule Angler.Admin.AccountAction do
  @moduledoc """
  Moderation log row. One per moderator action against an account
  (suspend, silence, disable, sensitive, none-with-warning).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Profiles.Profile
  alias Angler.Reports.Report

  @actions ~w(none disable silence suspend sensitive)

  schema "account_actions" do
    field :action, :string
    field :text, :string
    field :send_email_notification, :boolean, default: false
    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}

    belongs_to :target_account, Profile, type: :integer
    belongs_to :moderator_account, Profile, type: :integer
    belongs_to :report, Report, type: :integer
  end

  def changeset(action \\ %__MODULE__{}, attrs) do
    action
    |> cast(attrs, [
      :target_account_id,
      :moderator_account_id,
      :report_id,
      :action,
      :text,
      :send_email_notification
    ])
    |> validate_required([:target_account_id, :action])
    |> validate_inclusion(:action, @actions)
  end

  def actions, do: @actions
end
