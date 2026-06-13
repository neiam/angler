defmodule Angler.Accounts.Settings do
  @moduledoc """
  Read/write helpers around `Angler.Accounts.UserSettings`.
  """

  alias Angler.Accounts.UserSettings
  alias Angler.Repo

  @web_allowed_fields ~w(enable_reblogs hide_reblog_banner)

  # Account display/privacy settings surfaced in the account `settings` block.
  # These have no dedicated profiles column (the ones that do — `indexable`
  # ↔ indexable_search, `is_suggestable` ↔ discoverable — are read straight
  # off the profile). `default_scope` backs `source[privacy]`.
  @account_defaults %{
    "crawlable" => true,
    "disable_embeds" => false,
    "high_contrast_mode" => false,
    "media_descriptions" => false,
    "public_dm" => false,
    "reduce_motion" => false,
    "show_atom" => false,
    "show_profile_follower_count" => true,
    "show_profile_following_count" => true,
    "video_autoplay" => true,
    "default_scope" => "public"
  }

  @account_bool_fields ~w(
    crawlable disable_embeds high_contrast_mode media_descriptions public_dm
    reduce_motion show_atom show_profile_follower_count show_profile_following_count
    video_autoplay
  )

  @doc "Allowed `web/settings` field names (Pixelfed allowlist)."
  def web_allowed_fields, do: @web_allowed_fields

  @doc "Account settings with defaults applied (stored values win)."
  @spec account_settings(integer()) :: map()
  def account_settings(user_id) when is_integer(user_id) do
    Map.merge(@account_defaults, get(user_id).account || %{})
  end

  @doc "Default-only account settings (no DB read) — for rendering other users."
  @spec account_defaults() :: map()
  def account_defaults, do: @account_defaults

  @doc """
  Merge a partial map of account settings (string keys) into the stored blob,
  dropping unknown keys. Returns the settings map with defaults applied.
  """
  @spec merge_account(integer(), map()) :: {:ok, map()}
  def merge_account(user_id, partial) when is_integer(user_id) and is_map(partial) do
    allowed = Map.take(partial, ["default_scope" | @account_bool_fields])

    if allowed == %{} do
      {:ok, account_settings(user_id)}
    else
      row = get(user_id)
      account = Map.merge(row.account || %{}, allowed)
      {:ok, _} = row |> UserSettings.changeset(%{account: account}) |> Repo.update()
      {:ok, Map.merge(@account_defaults, account)}
    end
  end

  @doc """
  Extract the account settings the Pixelfed app sends through
  `update_credentials` (flat boolean params + `source[privacy]`) and persist
  them. Booleans arrive as query-string strings, so they're coerced.
  """
  @spec apply_account_params(integer(), map()) :: {:ok, map()}
  def apply_account_params(user_id, params) when is_integer(user_id) and is_map(params) do
    bools =
      for f <- @account_bool_fields, Map.has_key?(params, f), into: %{} do
        {f, truthy?(params[f])}
      end

    scope =
      case get_in(params, ["source", "privacy"]) do
        s when s in ["public", "unlisted", "private"] -> %{"default_scope" => s}
        _ -> %{}
      end

    merge_account(user_id, Map.merge(bools, scope))
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  @spec get(integer()) :: UserSettings.t()
  def get(user_id) when is_integer(user_id) do
    case Repo.get_by(UserSettings, user_id: user_id) do
      nil ->
        {:ok, row} =
          %UserSettings{} |> UserSettings.changeset(%{user_id: user_id}) |> Repo.insert()

        row

      row ->
        row
    end
  end

  @spec set_web_field(integer(), String.t(), term()) ::
          {:ok, UserSettings.t()} | {:error, :unknown_field}
  def set_web_field(user_id, field, value) when is_binary(field) do
    if field in @web_allowed_fields do
      row = get(user_id)
      web = Map.put(row.web || %{}, field, value)

      row
      |> UserSettings.changeset(%{web: web})
      |> Repo.update()
    else
      {:error, :unknown_field}
    end
  end

  @spec set_app(integer(), map()) :: {:ok, UserSettings.t()}
  def set_app(user_id, common) when is_map(common) do
    row = get(user_id)
    row |> UserSettings.changeset(%{app: common}) |> Repo.update()
  end
end
