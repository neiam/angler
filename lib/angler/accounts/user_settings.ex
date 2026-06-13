defmodule Angler.Accounts.UserSettings do
  @moduledoc """
  Per-user JSON blobs the Pixelfed mobile + web clients persist between
  sessions:

    * `web` — small key/value map of UI toggles (`enable_reblogs`,
      `hide_reblog_banner`, etc.). Whitelisted in `Settings.set_web_field/3`.
    * `app` — the mobile app's free-form `common` blob. Stored as-is.
    * `account` — display/privacy toggles surfaced in the account `settings`
      block (`crawlable`, `public_dm`, `show_profile_*_count`, etc.) plus the
      default post scope. Whitelisted in `Settings.merge_account/2`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Accounts.User

  schema "user_settings" do
    field :web, :map, default: %{}
    field :app, :map, default: %{}
    field :account, :map, default: %{}
    belongs_to :user, User, type: :integer
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(s \\ %__MODULE__{}, attrs) do
    s
    |> cast(attrs, [:user_id, :web, :app, :account])
    |> validate_required([:user_id])
    |> unique_constraint(:user_id)
  end
end
