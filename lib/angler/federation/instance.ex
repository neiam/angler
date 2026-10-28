defmodule Angler.Federation.Instance do
  @moduledoc """
  Known peer instance metadata + admin moderation flags.

  See `plans/federation/models/instance.md`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "instances" do
    field :domain, :string
    field :software, :string
    field :version, :string
    field :description, :string
    field :open_registrations, :boolean, default: true
    field :user_count, :integer
    field :status_count, :integer
    field :nodeinfo, :map

    field :banned, :boolean, default: false
    field :ban_reason, :string
    field :ban_severity, :string
    field :reject_media, :boolean, default: false
    field :reject_reports, :boolean, default: false
    field :public_comments, :string
    field :private_comments, :string

    # Softer admin moderation flags driven by the Pixelfed admin UI.
    field :unlisted, :boolean, default: false
    field :auto_cw, :boolean, default: false

    field :last_fetched_at, :utc_datetime_usec
    field :unreachable_since, :utc_datetime_usec

    # Outbound delivery health, managed by `Angler.Federation.DeliveryHosts`.
    field :delivery_failures, :integer, default: 0
    field :delivery_timeout, :boolean, default: false
    field :delivery_next_after, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def upsert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :domain,
      :software,
      :version,
      :description,
      :open_registrations,
      :user_count,
      :status_count,
      :nodeinfo,
      :last_fetched_at
    ])
    |> validate_required([:domain])
    |> update_change(:domain, &String.downcase/1)
    |> unique_constraint(:domain)
  end

  @doc false
  def moderation_changeset(instance, attrs) do
    instance
    |> cast(attrs, [
      :banned,
      :ban_reason,
      :ban_severity,
      :reject_media,
      :reject_reports,
      :public_comments,
      :private_comments,
      :unlisted,
      :auto_cw
    ])
  end
end
