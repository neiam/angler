defmodule Angler.Reports.Report do
  @moduledoc "User report against a profile, post, or story."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Accounts.User
  alias Angler.Profiles.Profile

  @types ~w(spam sensitive abusive underage violence copyright impersonation scam terrorism)
  @object_types ~w(post user story direct_message)

  @primary_key {:id, :integer, autogenerate: false}
  schema "reports" do
    field :object_id, :integer
    field :object_type, :string
    field :reported_profile_id, :integer
    field :type, :string
    field :resolved_at, :utc_datetime_usec

    field :assigned_account_id, :integer
    field :action_taken, :boolean, default: false
    field :action_taken_at, :utc_datetime_usec
    field :action_taken_by_account_id, :integer
    field :moderator_comment, :string
    field :message, :string

    belongs_to :profile, Profile, type: :integer
    belongs_to :user, User, type: :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(report \\ %__MODULE__{}, attrs) do
    report
    |> maybe_assign_id()
    |> cast(attrs, [
      :profile_id,
      :user_id,
      :object_id,
      :object_type,
      :reported_profile_id,
      :type,
      :resolved_at,
      :assigned_account_id,
      :action_taken,
      :action_taken_at,
      :action_taken_by_account_id,
      :moderator_comment,
      :message
    ])
    |> validate_required([:profile_id, :user_id, :object_id, :object_type, :type])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:object_type, @object_types)
    |> unique_constraint([:user_id, :object_type, :object_id])
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = r), do: %{r | id: Angler.Snowflake.next()}
  defp maybe_assign_id(r), do: r

  def types, do: @types
  def object_types, do: @object_types
end
