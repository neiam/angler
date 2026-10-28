defmodule Angler.SitePages.Page do
  @moduledoc "An admin-written `/site/*` page: Markdown keyed by slug (upstream `Page`)."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "site_pages" do
    field :slug, :string
    field :title, :string
    field :content, :string, default: ""

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(page \\ %__MODULE__{}, attrs) do
    page
    |> cast(attrs, [:title, :content])
    |> validate_length(:title, max: 120)
    |> validate_length(:content, max: 100_000)
    |> unique_constraint(:slug)
  end
end
