defmodule Angler.Instance.Settings do
  @moduledoc """
  Singleton row of operator-editable instance metadata. Each field overrides
  the matching env config when set; `nil` means "fall back to env" (see
  `Angler.Instance`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "instance_settings" do
    field :title, :string
    field :short_description, :string
    field :description, :string
    field :contact_email, :string
    field :contact_username, :string
    field :rules, {:array, :string}
    # Admin overrides for `config :angler, :captcha` / `:curated_registration`,
    # string-keyed; a missing key (or a nil map) falls back to env.
    field :captcha, :map
    field :curated_registration, :map
    # Admin config switches (`Angler.Instance.toggle/2`), string-keyed.
    field :toggles, :map
    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(title short_description description contact_email contact_username rules)a

  @string_fields ~w(title short_description description contact_email contact_username)a

  @doc "Changeset for the captcha / curated-registration overrides."
  def registration_changeset(settings, attrs),
    do: cast(settings, attrs, [:captcha, :curated_registration, :toggles])

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, @fields)
    |> blank_strings_to_nil()
    |> validate_length(:title, max: 120)
    |> validate_length(:short_description, max: 280)
    |> validate_length(:contact_email, max: 254)
    |> maybe_validate_email()
    |> normalize_rules()
  end

  # An empty field clears the override (falls back to env), so blanks → nil.
  defp blank_strings_to_nil(changeset) do
    Enum.reduce(@string_fields, changeset, fn field, cs ->
      case get_change(cs, field) do
        v when is_binary(v) -> if String.trim(v) == "", do: put_change(cs, field, nil), else: cs
        _ -> cs
      end
    end)
  end

  defp maybe_validate_email(changeset) do
    case get_change(changeset, :contact_email) do
      nil ->
        changeset

      _ ->
        validate_format(changeset, :contact_email, ~r/^[^\s@]+@[^\s@]+$/, message: "is invalid")
    end
  end

  defp normalize_rules(changeset) do
    case get_change(changeset, :rules) do
      nil ->
        changeset

      list when is_list(list) ->
        cleaned = list |> Enum.map(&String.trim(to_string(&1))) |> Enum.reject(&(&1 == ""))
        put_change(changeset, :rules, cleaned)

      _ ->
        put_change(changeset, :rules, [])
    end
  end
end
