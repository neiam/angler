defmodule Angler.Filters.Filter do
  @moduledoc "Server-side keyword/regex filter (Mastodon v2 shape)."

  use Ecto.Schema
  import Ecto.Changeset

  alias Angler.Filters.Keyword, as: FilterKeyword
  alias Angler.Profiles.Profile

  @contexts ~w(home notifications public thread account)
  @actions ~w(blur warn hide)

  @primary_key {:id, :integer, autogenerate: false}
  schema "filters" do
    field :title, :string
    field :contexts, {:array, :string}, default: []
    field :filter_action, :string, default: "warn"
    field :expires_at, :utc_datetime_usec
    belongs_to :profile, Profile, type: :integer
    has_many :keywords, FilterKeyword
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(filter \\ %__MODULE__{}, attrs) do
    filter
    |> maybe_assign_id()
    |> cast(attrs, [:profile_id, :title, :contexts, :filter_action, :expires_at])
    |> validate_required([:profile_id, :title])
    |> validate_inclusion(:filter_action, @actions)
    |> validate_change(:contexts, fn :contexts, list ->
      bad = Enum.reject(list, &(&1 in @contexts))
      if bad == [], do: [], else: [contexts: "unknown context: #{Enum.join(bad, ", ")}"]
    end)
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = f), do: %{f | id: Angler.Snowflake.next()}
  defp maybe_assign_id(f), do: f

  def contexts, do: @contexts
  def actions, do: @actions
end
