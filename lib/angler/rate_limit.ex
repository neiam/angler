defmodule Angler.RateLimit do
  @moduledoc """
  Fixed-window failure counters for brute-forceable endpoints (password
  login, the OAuth password grant, the 2FA checkpoint).

  Counters live in a public ETS table owned by this process, so they are per
  node: across a cluster an attacker gets one budget per pod. That is a
  bounded multiple, which is enough to make guessing impractical.

      if RateLimit.allowed?(key, 10, 900) do
        case check() do
          :ok -> RateLimit.reset(key)
          :error -> RateLimit.fail(key, 900)
        end
      end
  """

  use GenServer

  @table __MODULE__
  @sweep_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Whether `key` has had fewer than `limit` failures in its current window."
  @spec allowed?(term(), pos_integer(), pos_integer()) :: boolean()
  def allowed?(key, limit, _window_s) do
    now = now_ms()

    case :ets.lookup(@table, key) do
      [{^key, count, expires_at}] when expires_at > now -> count < limit
      _ -> true
    end
  end

  @doc "Record a failure for `key`; the window starts at the first failure."
  @spec fail(term(), pos_integer()) :: :ok
  def fail(key, window_s) do
    now = now_ms()
    expires_at = now + window_s * 1_000

    case :ets.lookup(@table, key) do
      [{^key, _count, at}] when at > now -> :ets.update_counter(@table, key, {2, 1})
      _ -> :ets.insert(@table, {key, 1, expires_at})
    end

    :ok
  end

  @doc "Clear `key`'s counter (after a success)."
  @spec reset(term()) :: :ok
  def reset(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc "Clear every counter. For tests: the table outlives each test's sandbox."
  @spec reset_all() :: :ok
  def reset_all do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now_ms()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
