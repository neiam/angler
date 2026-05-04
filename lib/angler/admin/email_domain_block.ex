defmodule Angler.Admin.EmailDomainBlock do
  @moduledoc "Block emails from a specific domain at signup."

  use Ecto.Schema
  import Ecto.Changeset

  schema "email_domain_blocks" do
    field :domain, :string
    field :allow_with_approval, :boolean, default: false
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(b \\ %__MODULE__{}, attrs) do
    b
    |> cast(attrs, [:domain, :allow_with_approval])
    |> validate_required([:domain])
    |> update_change(:domain, &String.downcase/1)
    |> unique_constraint(:domain)
  end
end
