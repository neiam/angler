defmodule Angler.Hashtags.CountCache do
  @moduledoc """
  Per-tag cache of hashtag usage counts (see `Angler.Hashtags.usage_counts/1`).

  An ETS table of `{name, count, expires_at}`; this process only owns the table
  and sweeps expired rows. Reads and writes happen in the caller, so a cache
  miss costs the caller one query and nobody else.
  """
  use GenServer

  @table __MODULE__
  @sweep_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The cached counts among `names` still fresh at `now` (monotonic ms)."
  @spec fresh([String.t()], integer()) :: %{optional(String.t()) => non_neg_integer()}
  def fresh(names, now) do
    for name <- names,
        [{^name, count, expires_at}] <- [:ets.lookup(@table, name)],
        expires_at > now,
        into: %{},
        do: {name, count}
  end

  @doc "Cache `counts` (name => count) until `expires_at` (monotonic ms)."
  @spec put(%{optional(String.t()) => non_neg_integer()}, integer()) :: :ok
  def put(counts, expires_at) do
    :ets.insert(@table, Enum.map(counts, fn {name, count} -> {name, count, expires_at} end))
    :ok
  end

  @doc "Drop every cached count."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
