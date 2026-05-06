defmodule Angler.Groups.Group do
  @moduledoc "A community group; statuses can be scoped to one via `Status.group_id`."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Groups.Category
  alias Angler.Profiles.Profile

  @privacies ~w(public private secret)
  @policies ~w(members admins)

  @primary_key {:id, :integer, autogenerate: false}
  schema "groups" do
    field :name, :string
    field :slug, :string
    field :description, :string

    field :privacy, :string, default: "public"
    field :discoverable, :boolean, default: true
    field :post_policy, :string, default: "members"
    field :comment_policy, :string, default: "members"

    field :avatar_path, :string
    field :header_path, :string

    field :member_count, :integer, default: 1
    field :post_count, :integer, default: 0

    belongs_to :owner, Profile, foreign_key: :owner_profile_id, type: :integer
    belongs_to :category, Category, type: :integer

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(
    name slug description owner_profile_id category_id
    privacy discoverable post_policy comment_policy
    avatar_path header_path member_count post_count
  )a

  def changeset(group \\ %__MODULE__{}, attrs) do
    group
    |> maybe_assign_id()
    |> cast(attrs, [:id | @cast_fields])
    |> validate_required([:name, :slug, :owner_profile_id])
    |> validate_inclusion(:privacy, @privacies)
    |> validate_inclusion(:post_policy, @policies)
    |> validate_inclusion(:comment_policy, @policies)
    |> validate_length(:name, min: 1, max: 80)
    |> update_change(:slug, &String.downcase/1)
    |> unique_constraint(:slug)
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = g), do: %{g | id: Angler.Snowflake.next()}
  defp maybe_assign_id(g), do: g

  def privacies, do: @privacies
  def policies, do: @policies
end
