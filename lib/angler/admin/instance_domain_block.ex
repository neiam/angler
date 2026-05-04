defmodule Angler.Admin.InstanceDomainBlock do
  @moduledoc """
  Instance-level defederation entry. Severity:

    * `silence` — federation continues but the domain's posts are hidden
      from the public timeline (Mastodon convention).
    * `suspend` — full defederation; we drop inbound activities and skip
      outbound delivery.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @severities ~w(silence suspend noop)

  schema "instance_domain_blocks" do
    field :domain, :string
    field :severity, :string, default: "silence"
    field :reject_media, :boolean, default: false
    field :reject_reports, :boolean, default: false
    field :public_comment, :string
    field :private_comment, :string
    field :obfuscate, :boolean, default: false
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(b \\ %__MODULE__{}, attrs) do
    b
    |> cast(attrs, [
      :domain,
      :severity,
      :reject_media,
      :reject_reports,
      :public_comment,
      :private_comment,
      :obfuscate
    ])
    |> validate_required([:domain, :severity])
    |> update_change(:domain, &String.downcase/1)
    |> validate_inclusion(:severity, @severities)
    |> unique_constraint(:domain)
  end

  def severities, do: @severities
end
