defmodule Angler.Accounts.Settings do
  @moduledoc """
  Read/write helpers around `Angler.Accounts.UserSettings`.
  """

  alias Angler.Accounts.User
  alias Angler.Accounts.UserSettings
  alias Angler.Repo

  @web_allowed_fields ~w(enable_reblogs hide_reblog_banner photo_reblogs_only)

  # Account display/privacy settings surfaced in the account `settings` block.
  # These have no dedicated profiles column (the ones that do — `indexable`
  # ↔ indexable_search, `is_suggestable` ↔ discoverable — are read straight
  # off the profile). `default_scope` backs `source[privacy]`; `can_quote`
  # (who may quote your posts, `Angler.Quotes`) backs `source[quote_policy]`;
  # `can_feature` is who may feature you (`Angler.FeaturedCollections`).
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
    "default_scope" => "public",
    "can_quote" => "everyone",
    "can_feature" => "everyone"
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
    allowed =
      Map.take(partial, ["default_scope", "can_quote", "can_feature" | @account_bool_fields])

    if allowed == %{} do
      {:ok, account_settings(user_id)}
    else
      row = get(user_id)
      before = Map.merge(@account_defaults, row.account || %{})
      account = Map.merge(row.account || %{}, allowed)
      {:ok, _} = row |> UserSettings.changeset(%{account: account}) |> Repo.update()
      after_ = Map.merge(@account_defaults, account)

      if before["can_feature"] != after_["can_feature"] do
        %User{profile_id: pid} = Repo.get!(User, user_id)
        :ok = Angler.FeaturedCollections.policy_changed(pid)
      end

      {:ok, after_}
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

    can_quote =
      case Angler.Quotes.account_policy_param(
             params["can_quote"] || get_in(params, ["source", "quote_policy"])
           ) do
        nil -> %{}
        p -> %{"can_quote" => p}
      end

    can_feature =
      case Angler.FeaturedCollections.policy_param(params["can_feature"]) do
        nil -> %{}
        p -> %{"can_feature" => p}
      end

    merge_account(
      user_id,
      bools |> Map.merge(scope) |> Map.merge(can_quote) |> Map.merge(can_feature)
    )
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

  ## Default media license (Pixelfed compose-setting parity)

  @doc """
  The user's default media license id (integer). Falls back to `1`
  (All Rights Reserved) when unset. The id is validated against
  `Angler.Media.License` on write, so a stored value is always known.
  """
  @spec default_license(integer()) :: pos_integer()
  def default_license(user_id) when is_integer(user_id) do
    case get(user_id).account["default_license"] do
      n when is_integer(n) -> n
      s when is_binary(s) -> String.to_integer(s)
      _ -> 1
    end
  end

  @doc "Resolve a profile's owning user's default license id, or `1` if none."
  @spec default_license_for_profile(integer()) :: pos_integer()
  def default_license_for_profile(profile_id) when is_integer(profile_id) do
    case Repo.get_by(User, profile_id: profile_id) do
      %User{id: user_id} -> default_license(user_id)
      _ -> 1
    end
  end

  @doc """
  Persist the user's default media license. `license_id` must be a known
  `Angler.Media.License` id; otherwise `{:error, :invalid_license}`.
  """
  @spec set_default_license(integer(), integer() | String.t()) ::
          {:ok, pos_integer()} | {:error, :invalid_license}
  def set_default_license(user_id, license_id) when is_integer(user_id) do
    id =
      case license_id do
        n when is_integer(n) ->
          n

        s when is_binary(s) ->
          case Integer.parse(s) do
            {n, _} -> n
            :error -> nil
          end

        _ ->
          nil
      end

    if id && Angler.Media.License.valid?(id) do
      row = get(user_id)
      account = Map.put(row.account || %{}, "default_license", id)
      {:ok, _} = row |> UserSettings.changeset(%{account: account}) |> Repo.update()
      {:ok, id}
    else
      {:error, :invalid_license}
    end
  end
end
