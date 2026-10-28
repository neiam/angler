defmodule Angler.CuratedRegistrations.Activity do
  @moduledoc """
  One entry in an application's thread (upstream
  `App\\Models\\CuratedRegisterActivity`): an admin's request for more
  details (`request_details`, carrying a hashed one-time reply code), the
  applicant's answer (`user_response`, linked by `reply_to_id`), or a
  confirmation-email resend (`user_resend_email_confirmation`).
  """

  use Ecto.Schema

  alias Angler.Accounts.User
  alias Angler.CuratedRegistrations.CuratedRegister

  schema "curated_register_activities" do
    field :secret_code_hash, :binary, redact: true
    field :type, :string
    field :message, :string
    field :from_admin, :boolean, default: false
    field :from_user, :boolean, default: false
    field :admin_only_view, :boolean, default: true
    field :action_required, :boolean, default: false

    belongs_to :register, CuratedRegister
    belongs_to :admin, User
    belongs_to :reply_to, __MODULE__

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
