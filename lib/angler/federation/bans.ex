defmodule Angler.Federation.Bans do
  @moduledoc """
  Banned-domain set with a small in-process cache.

  A `:persistent_term` table is filled from the `instances` table on first
  read and refreshed every 5 minutes. Admin writes invalidate by calling
  `bust/0`. The hot path (every inbound POST) is then a constant-time set
  membership check.
  """

  import Ecto.Query, warn: false

  alias Angler.Federation.Instance
  alias Angler.Repo

  @key {__MODULE__, :banned_set}
  @ttl_ms 5 * 60 * 1000

  @doc "Whether the given host is admin-banned. Lazily refreshed."
  @spec banned?(String.t()) :: boolean()
  def banned?(host) when is_binary(host) do
    %{set: set} = current()
    MapSet.member?(set, String.downcase(host))
  end

  @doc "Return the banned-host set (for admin/debug)."
  @spec list() :: MapSet.t()
  def list do
    %{set: set} = current()
    set
  end

  @doc "Force a refresh on next read."
  @spec bust() :: :ok
  def bust, do: :persistent_term.erase(@key) && :ok

  ## Internals

  defp current do
    case :persistent_term.get(@key, nil) do
      %{loaded_at: loaded_at} = state ->
        if System.monotonic_time(:millisecond) - loaded_at > @ttl_ms do
          load()
        else
          state
        end

      nil ->
        load()
    end
  end

  defp load do
    set =
      from(i in Instance, where: i.banned == true, select: i.domain)
      |> Repo.all()
      |> Enum.map(&String.downcase/1)
      |> MapSet.new()

    state = %{set: set, loaded_at: System.monotonic_time(:millisecond)}
    :persistent_term.put(@key, state)
    state
  end
end
