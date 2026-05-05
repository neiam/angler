defmodule Angler.Profiles.Profile do
  @moduledoc """
  Display + ActivityPub identity for a single account.

  Local profiles have a `private_key_pem` and no `domain`. Remote profiles have
  a `domain`, no private key, and an `inbox_url`/`shared_inbox_url`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  # We assign a snowflake id explicitly in the changeset rather than relying on
  # `Ecto.Type.autogenerate/0` because Ecto's primary-key autogenerate hook only
  # works reliably for `:id` and `:binary_id`. See `maybe_assign_id/1` below.
  @primary_key {:id, :integer, autogenerate: false}
  schema "profiles" do
    field :username, :string
    field :domain, :string
    field :name, :string
    field :bio, :string
    field :bio_text, :string
    field :website, :string
    field :location, :string

    field :is_private, :boolean, default: false
    field :discoverable, :boolean, default: true
    field :indexable_search, :boolean, default: true
    field :directory_opt_in, :boolean, default: false
    field :is_bot, :boolean, default: false
    field :is_suspended, :boolean, default: false
    field :status, :string

    field :avatar_path, :string
    field :header_path, :string

    field :public_key_pem, :string
    field :private_key_pem, :binary

    field :inbox_url, :string
    field :outbox_url, :string
    field :shared_inbox_url, :string
    field :followers_url, :string
    field :following_url, :string
    field :remote_url, :string

    field :followers_count, :integer, default: 0
    field :following_count, :integer, default: 0
    field :statuses_count, :integer, default: 0

    field :last_status_at, :utc_datetime_usec
    field :last_fetched_at, :utc_datetime_usec
    field :last_active_at, :utc_datetime_usec

    field :moved_to_id, :id
    field :also_known_as, {:array, :string}, default: []

    # Pixelfed-shape per-profile admin moderation flags. Distinct from the
    # auth/user-facing `is_suspended` and `status` fields.
    field :unlisted, :boolean, default: false
    field :cw, :boolean, default: false
    field :no_autolink, :boolean, default: false

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(
    username domain name bio bio_text website location
    is_private discoverable indexable_search directory_opt_in is_bot is_suspended status
    avatar_path header_path
    public_key_pem private_key_pem
    inbox_url outbox_url shared_inbox_url followers_url following_url remote_url
    last_status_at last_fetched_at last_active_at
    moved_to_id also_known_as
    unlisted cw no_autolink
  )a

  @doc false
  def changeset(profile, attrs) do
    profile
    |> maybe_assign_id()
    |> cast(attrs, @cast_fields)
    |> validate_required([:username])
    |> validate_length(:username, min: 1, max: 30)
    |> validate_format(:username, ~r/^[A-Za-z0-9_.-]+$/)
    |> unique_constraint([:username, :domain], name: :profiles_username_domain_idx)
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = profile),
    do: %{profile | id: Angler.Snowflake.next()}

  defp maybe_assign_id(profile), do: profile

  @update_credentials_fields ~w(
    display_name note locked bot discoverable indexable website avatar_path header_path
  )

  @doc """
  Changeset for `PATCH /api/v1/accounts/update_credentials`. Maps Mastodon
  field names onto our schema. Strips HTML from `note` (Mastodon expects
  raw text in; we render HTML on the way out).
  """
  def update_credentials_changeset(profile, attrs) when is_map(attrs) do
    mapped =
      attrs
      |> Map.take(@update_credentials_fields)
      |> Map.new(fn {k, v} -> {schema_key(k), v} end)

    profile
    |> cast(mapped, [
      :name,
      :bio,
      :bio_text,
      :is_private,
      :is_bot,
      :discoverable,
      :indexable_search,
      :website,
      :avatar_path,
      :header_path
    ])
    |> validate_length(:name, max: 30)
    |> validate_length(:bio_text, max: 200)
    |> validate_length(:website, max: 120)
    |> render_bio()
  end

  defp render_bio(changeset) do
    case get_change(changeset, :bio_text) do
      nil ->
        changeset

      raw ->
        put_change(changeset, :bio, render_text_to_html(raw))
    end
  end

  defp render_text_to_html(""), do: ""

  defp render_text_to_html(raw) when is_binary(raw) do
    raw
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
    |> String.replace("\n", "<br>")
  end

  defp schema_key("display_name"), do: :name
  defp schema_key("note"), do: :bio_text
  defp schema_key("locked"), do: :is_private
  defp schema_key("bot"), do: :is_bot
  defp schema_key("discoverable"), do: :discoverable
  defp schema_key("indexable"), do: :indexable_search
  defp schema_key("website"), do: :website
  defp schema_key("avatar_path"), do: :avatar_path
  defp schema_key("header_path"), do: :header_path
  defp schema_key(other), do: other
end
