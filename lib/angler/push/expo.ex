defmodule Angler.Push.Expo do
  @moduledoc """
  Pixelfed-style Expo push token registry.

  The mobile Pixelfed app (and forks) uses Expo's push gateway to deliver
  iOS/Android notifications. This module persists the per-user token plus
  per-category opt-in flags. Outbound delivery is gated on the operator
  enabling `:expo_push_enabled` (default `false`); when off, all reads
  return `enabled: false` and writes 404 at the controller layer.

  Distinct from `Angler.Push` which is the Mastodon-shape WebPush
  subscription (per-OAuth-token, browser-side).
  """

  @push_gateway_version "0.4"

  alias Angler.Accounts.User
  alias Angler.Repo

  @doc "Whether the operator has enabled the Expo push subscription surface."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:angler, :expo_push_enabled, false) == true

  @doc "Pixelfed PushNotificationService::PUSH_GATEWAY_VERSION analogue."
  @spec gateway_version() :: String.t()
  def gateway_version, do: @push_gateway_version

  @doc "Snapshot of the user's current push state for `GET /push/state`."
  @spec state(User.t()) :: map()
  def state(%User{} = user) do
    %{
      "version" => @push_gateway_version,
      "username" => username_of(user),
      "profile_id" => Integer.to_string(user.profile_id),
      "notify_enabled" => !!user.notify_enabled,
      "has_token" => is_binary(user.expo_token) and user.expo_token != "",
      "notify_like" => !!user.notify_like,
      "notify_follow" => !!user.notify_follow,
      "notify_mention" => !!user.notify_mention,
      "notify_comment" => !!user.notify_comment
    }
  end

  @doc """
  Compare a candidate token against the persisted one.
  Returns `:no_token` when the user has no stored token, otherwise
  `:match | :mismatch`. Comparison is constant-time.
  """
  @spec compare(User.t(), String.t()) :: :match | :mismatch | :no_token
  def compare(%User{expo_token: nil}, _candidate), do: :no_token
  def compare(%User{expo_token: ""}, _candidate), do: :no_token

  def compare(%User{expo_token: known}, candidate) when is_binary(candidate) do
    if Plug.Crypto.secure_compare(known, candidate), do: :match, else: :mismatch
  end

  def compare(_, _), do: :mismatch

  @doc """
  Update the persisted token + alert flags. Caller is expected to have
  validated `expo_token` already (Pixelfed enforces an `ExponentPushToken[…]`
  format — we apply the same regex via `valid_token?/1`).
  """
  @spec update(User.t(), map()) ::
          {:ok, User.t()} | {:error, :token_in_use | Ecto.Changeset.t()}
  def update(%User{} = user, attrs) when is_map(attrs) do
    token = attrs["token"] || attrs[:token]

    cond do
      not is_binary(token) or not valid_token?(token) ->
        {:error, fake_changeset(:token, "is invalid")}

      token_collision?(user, token) ->
        {:error, :token_in_use}

      true ->
        user
        |> Ecto.Changeset.change(
          expo_token: token,
          notify_enabled: truthy?(attrs["notify_enabled"], user.notify_enabled),
          notify_like: truthy?(attrs["notify_like"], user.notify_like),
          notify_follow: truthy?(attrs["notify_follow"], user.notify_follow),
          notify_mention: truthy?(attrs["notify_mention"], user.notify_mention),
          notify_comment: truthy?(attrs["notify_comment"], user.notify_comment)
        )
        |> Repo.update()
    end
  end

  @doc "Clear the user's Expo subscription. Idempotent."
  @spec disable(User.t()) :: {:ok, User.t()}
  def disable(%User{} = user) do
    user
    |> Ecto.Changeset.change(
      expo_token: nil,
      notify_enabled: false,
      notify_like: false,
      notify_follow: false,
      notify_mention: false,
      notify_comment: false
    )
    |> Repo.update()
  end

  @expo_token_regex ~r/^ExponentPushToken\[[A-Za-z0-9_-]+\]$/

  @doc "Strict Expo token format check; matches Pixelfed's ExpoPushTokenRule."
  @spec valid_token?(String.t()) :: boolean()
  def valid_token?(token) when is_binary(token), do: Regex.match?(@expo_token_regex, token)
  def valid_token?(_), do: false

  defp token_collision?(%User{id: uid}, token) do
    import Ecto.Query, only: [from: 2]

    other =
      Repo.aggregate(
        from(u in User, where: u.expo_token == ^token and u.id != ^uid),
        :count
      )

    other > 5
  end

  defp username_of(%User{profile: %Angler.Profiles.Profile{username: u}}) when is_binary(u), do: u

  defp username_of(%User{profile_id: pid}) do
    case Repo.get(Angler.Profiles.Profile, pid) do
      %{username: u} -> u
      _ -> ""
    end
  end

  defp truthy?(nil, default), do: default
  defp truthy?(true, _), do: true
  defp truthy?(false, _), do: false
  defp truthy?("true", _), do: true
  defp truthy?("1", _), do: true
  defp truthy?(1, _), do: true
  defp truthy?("false", _), do: false
  defp truthy?("0", _), do: false
  defp truthy?(0, _), do: false
  defp truthy?(_, default), do: default

  defp fake_changeset(field, msg) do
    %Ecto.Changeset{
      types: %{field => :string},
      data: %{},
      valid?: false,
      errors: [{field, {msg, []}}],
      action: :update
    }
  end
end
