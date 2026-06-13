defmodule Angler.Instance do
  @moduledoc """
  Instance metadata + counts that back `GET /api/v1/instance` and the v2
  variant. Reads are cached for 30 minutes via `:persistent_term` since the
  numbers don't move much and clients hit this on every cold start.
  """

  import Ecto.Query, warn: false

  alias Angler.Accounts.User
  alias Angler.Federation.Instance
  alias Angler.Instance.Settings
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses.Status

  @cache_key {__MODULE__, :stats}
  @cache_ttl_ms 30 * 60 * 1_000

  @doc """
  Returns `%{user_count, status_count, domain_count}` cached for half an hour.
  """
  @spec stats() :: %{user_count: integer(), status_count: integer(), domain_count: integer()}
  def stats do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@cache_key, :miss) do
      {value, expires_at} when is_integer(expires_at) and expires_at > now ->
        value

      _ ->
        value = compute_stats()
        :persistent_term.put(@cache_key, {value, now + @cache_ttl_ms})
        value
    end
  end

  defp compute_stats do
    %{
      user_count: Repo.aggregate(from(u in User, where: is_nil(u.status)), :count),
      status_count:
        Repo.aggregate(
          from(s in Status, where: is_nil(s.deleted_at) and s.local == true),
          :count
        ),
      domain_count: Repo.aggregate(Instance, :count)
    }
  end

  @doc """
  Find the contact account profile, if one is configured. Defaults to nil
  (no admin set up); rendered into the `contact_account` / `contact.account`
  field on the instance JSON.
  """
  @spec contact_profile() :: Profile.t() | nil
  def contact_profile do
    case settings().contact_username || Application.get_env(:angler, :instance_contact_username) do
      username when is_binary(username) -> Angler.Profiles.get_local_by_username(username)
      _ -> nil
    end
  end

  @doc "Operator contact email (DB override, else env), or nil."
  @spec contact_email() :: String.t() | nil
  def contact_email,
    do: settings().contact_email || Application.get_env(:angler, :instance_contact_email)

  @doc "Display title (DB override, else env, else host)."
  @spec title() :: String.t()
  def title do
    settings().title || Application.get_env(:angler, :instance_title) || host_from_endpoint()
  end

  @doc "Short description for the instance description block."
  @spec short_description() :: String.t()
  def short_description do
    settings().short_description ||
      Application.get_env(:angler, :instance_short_description) ||
      "Angler — a Pixelfed-compatible Phoenix backend."
  end

  @doc "Long description shown on the about page."
  @spec description() :: String.t()
  def description do
    settings().description || Application.get_env(:angler, :instance_description) ||
      short_description()
  end

  @doc "List of human-readable rule strings (DB override, else env)."
  @spec rules() :: [String.t()]
  def rules do
    case settings().rules do
      list when is_list(list) -> list
      _ -> Application.get_env(:angler, :instance_rules, [])
    end
  end

  ## Editable settings (singleton row; overrides env)

  @doc "Fetch the editable settings row (an empty `%Settings{}` if none yet)."
  @spec get_settings() :: Settings.t()
  def get_settings do
    Repo.one(from(s in Settings, order_by: [asc: s.id], limit: 1)) || %Settings{}
  end

  @doc "Upsert the singleton settings row."
  @spec update_settings(map()) :: {:ok, Settings.t()} | {:error, Ecto.Changeset.t()}
  def update_settings(attrs) do
    get_settings() |> Settings.changeset(attrs) |> Repo.insert_or_update()
  end

  # Singleton read (cheap single-row lookup; the override getters call this).
  defp settings, do: get_settings()

  @doc "Whether open registration is on. Default false."
  @spec open_registration?() :: boolean()
  def open_registration? do
    Application.get_env(:angler, :open_registration, false) == true
  end

  @doc "Whether moderator approval is required for new signups."
  @spec approval_required?() :: boolean()
  def approval_required? do
    Application.get_env(:angler, :registration_approval_required, false) == true
  end

  defp host_from_endpoint do
    AnglerWeb.Endpoint.url() |> URI.parse() |> Map.get(:host) || "localhost"
  end
end
