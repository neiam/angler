defmodule Angler.Instance do
  @moduledoc """
  Instance metadata + counts that back `GET /api/v1/instance` and the v2
  variant. Reads are cached for 30 minutes via `:persistent_term` since the
  numbers don't move much and clients hit this on every cold start.
  """

  import Ecto.Query, warn: false

  alias Angler.Accounts.User
  alias Angler.Federation.Instance
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
    case Application.get_env(:angler, :instance_contact_username) do
      username when is_binary(username) -> Angler.Profiles.get_local_by_username(username)
      _ -> nil
    end
  end

  @doc "Configured operator email for the instance, or nil."
  @spec contact_email() :: String.t() | nil
  def contact_email, do: Application.get_env(:angler, :instance_contact_email)

  @doc "Display title (defaults to host)."
  @spec title() :: String.t()
  def title do
    Application.get_env(:angler, :instance_title) || host_from_endpoint()
  end

  @doc "Short description for the instance description block."
  @spec short_description() :: String.t()
  def short_description do
    Application.get_env(:angler, :instance_short_description) ||
      "Angler — a Pixelfed-compatible Phoenix backend."
  end

  @doc "Long description shown on the about page."
  @spec description() :: String.t()
  def description do
    Application.get_env(:angler, :instance_description) || short_description()
  end

  @doc "List of human-readable rule strings configured by the operator."
  @spec rules() :: [String.t()]
  def rules, do: Application.get_env(:angler, :instance_rules, [])

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
