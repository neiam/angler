defmodule Angler.Snowflake do
  @moduledoc """
  64-bit Twitter-snowflake-style ID generator.

  Layout (high-to-low):

      | 1 bit unused | 41 bits ms since epoch | 10 bits node id | 12 bits sequence |

  This matches Pixelfed's id semantics so federation references stay sortable
  across instances.

  Configure via `config/runtime.exs`:

      config :angler, Angler.Snowflake,
        node_id: System.get_env("ANGLER_NODE_ID", "0") |> String.to_integer(),
        epoch: 1_577_836_800_000   # 2020-01-01 UTC, default

  At runtime IDs are produced through `Angler.Snowflake.next/0`. The Ecto type
  `Angler.Snowflake.Type` autogenerates them on insert.
  """

  use GenServer

  @max_node 0b11_1111_1111
  @max_seq 0b1111_1111_1111
  @node_shift 12
  @ts_shift 22

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec next() :: pos_integer()
  def next, do: GenServer.call(__MODULE__, :next)

  @doc "Returns the millisecond timestamp encoded in the given snowflake."
  @spec timestamp(pos_integer()) :: integer()
  def timestamp(id) when is_integer(id) do
    Bitwise.bsr(id, @ts_shift) + epoch()
  end

  @doc false
  def epoch do
    Application.get_env(:angler, __MODULE__, [])
    |> Keyword.get(:epoch, 1_577_836_800_000)
  end

  ## Server

  @impl true
  def init(opts) do
    node_id = Keyword.get(opts, :node_id, 0)

    if node_id < 0 or node_id > @max_node do
      raise ArgumentError, "node_id must be 0..#{@max_node}, got: #{inspect(node_id)}"
    end

    {:ok, %{node_id: node_id, last_ms: 0, seq: 0}}
  end

  @impl true
  def handle_call(:next, _from, state) do
    now = System.system_time(:millisecond)

    {ms, seq} =
      cond do
        now > state.last_ms ->
          {now, 0}

        now == state.last_ms ->
          if state.seq + 1 > @max_seq do
            wait_next_ms(state.last_ms)
            {state.last_ms + 1, 0}
          else
            {state.last_ms, state.seq + 1}
          end

        true ->
          # Clock went backwards. Stall to last_ms to keep monotonic.
          {state.last_ms, state.seq + 1}
      end

    id =
      Bitwise.bsl(ms - epoch(), @ts_shift)
      |> Bitwise.bor(Bitwise.bsl(state.node_id, @node_shift))
      |> Bitwise.bor(seq)

    {:reply, id, %{state | last_ms: ms, seq: seq}}
  end

  defp wait_next_ms(target_ms) do
    if System.system_time(:millisecond) <= target_ms do
      Process.sleep(1)
      wait_next_ms(target_ms)
    end
  end
end
