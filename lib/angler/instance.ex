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
  Returns `%{user_count, status_count, domain_count, active_month,
  active_halfyear, local_comments}` cached for half an hour.

  "Active" means the user authored a local status in the window — the only
  activity signal we record (`users.last_active_at` is never written).
  """
  @spec stats() :: %{
          user_count: integer(),
          status_count: integer(),
          domain_count: integer(),
          active_month: integer(),
          active_halfyear: integer(),
          local_comments: integer()
        }
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

  @doc "Drop the cached stats snapshot so the next read recomputes."
  @spec clear_stats_cache() :: :ok
  def clear_stats_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp compute_stats do
    local_statuses = from(s in Status, where: is_nil(s.deleted_at) and s.local == true)

    %{
      user_count: Repo.aggregate(from(u in User, where: is_nil(u.status)), :count),
      status_count: Repo.aggregate(local_statuses, :count),
      domain_count: Repo.aggregate(Instance, :count),
      active_month: active_users_since(local_statuses, 30),
      active_halfyear: active_users_since(local_statuses, 180),
      local_comments:
        Repo.aggregate(from(s in local_statuses, where: not is_nil(s.in_reply_to_id)), :count)
    }
  end

  defp active_users_since(local_statuses, days) do
    since = DateTime.add(DateTime.utc_now(), -days, :day)

    from(s in local_statuses,
      join: u in User,
      on: u.profile_id == s.profile_id and is_nil(u.status),
      where: s.inserted_at >= ^since,
      select: count(s.profile_id, :distinct)
    )
    |> Repo.one()
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
  def open_registration?, do: toggle(:open_registration, false)

  @doc """
  An admin config switch (`/api/admin/config`, the admin settings page):
  the saved value, else `config :angler, key` (env), else `default`. Saved
  in the database so it reaches every node and survives restarts.
  """
  @spec toggle(atom(), boolean()) :: boolean()
  def toggle(key, default) when is_atom(key) do
    case Map.fetch(settings().toggles || %{}, Atom.to_string(key)) do
      {:ok, v} -> v == true
      :error -> Application.get_env(:angler, key, default) == true
    end
  end

  @doc "Save an admin config switch."
  @spec put_toggle(atom(), boolean()) :: {:ok, Settings.t()} | {:error, Ecto.Changeset.t()}
  def put_toggle(key, value) when is_atom(key) and is_boolean(value) do
    s = get_settings()
    toggles = Map.put(s.toggles || %{}, Atom.to_string(key), value)
    s |> Settings.registration_changeset(%{toggles: toggles}) |> Repo.insert_or_update()
  end

  @doc "Whether moderator approval is required for new signups."
  @spec approval_required?() :: boolean()
  def approval_required? do
    Application.get_env(:angler, :registration_approval_required, false) == true
  end

  @doc """
  Whether curated registration is switched on (upstream
  `instance.curated_registration.enabled`). This is what the instance API
  reports as `approval_required`.
  """
  @spec curated_registration_enabled?() :: boolean()
  def curated_registration_enabled?, do: curated_config(:enabled, false) == true

  @doc """
  Whether the curated application form is open right now: switched on, and
  either registration is closed or the operator allows it alongside open
  registration (upstream `state.only_enabled_on_closed_reg`, default true).
  """
  @spec curated_registration?() :: boolean()
  def curated_registration? do
    curated_registration_enabled?() and
      (not open_registration?() or curated_config(:only_enabled_on_closed_reg, true) != true)
  end

  @doc """
  A curated-registration setting: the admin override (admin settings page),
  else `config :angler, :curated_registration`.
  """
  @spec curated_config(atom(), term()) :: term()
  def curated_config(key, default) do
    case override(:curated_registration, key) do
      {:ok, v} -> v
      :error -> Keyword.get(Application.get_env(:angler, :curated_registration, []), key, default)
    end
  end

  @doc """
  An admin override of a registration setting group (`:captcha` or
  `:curated_registration`), `:error` when unset so env applies.
  """
  @spec override(:captcha | :curated_registration, atom()) :: {:ok, term()} | :error
  def override(group, key) when group in [:captcha, :curated_registration] do
    case Map.get(settings(), group) do
      %{} = m ->
        case Map.fetch(m, Atom.to_string(key)) do
          {:ok, v} when not is_nil(v) -> {:ok, v}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @doc """
  Set (or with `nil` clear back to env) a registration setting group's
  overrides.
  """
  @spec update_registration_settings(:captcha | :curated_registration, map() | nil) ::
          {:ok, Settings.t()} | {:error, Ecto.Changeset.t()}
  def update_registration_settings(group, value)
      when group in [:captcha, :curated_registration] do
    get_settings()
    |> Settings.registration_changeset(%{group => value})
    |> Repo.insert_or_update()
  end

  @doc "Minimum age to register (upstream `pixelfed.min_registration_age`)."
  @spec min_registration_age() :: pos_integer()
  def min_registration_age, do: Application.get_env(:angler, :min_registration_age, 16)

  defp host_from_endpoint do
    AnglerWeb.Endpoint.url() |> URI.parse() |> Map.get(:host) || "localhost"
  end
end
