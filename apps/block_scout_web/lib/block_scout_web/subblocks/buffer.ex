defmodule BlockScoutWeb.Subblocks.Buffer do
  @moduledoc """
  The most recent subblocks the relay received, returned to a client when it joins `subblocks:new`.

  The process owns an ETS table keyed by `{block_number, index}`. Writes go through the process, which only the
  relay calls; any process reads the table directly.
  """

  use GenServer

  alias BlockScoutWeb.Subblocks.Frame

  @table :subblocks_buffer
  @max_items 60
  # the frontend calls the feed delayed after the same time without a subblock
  @stale_after_ms 5_000
  # what came before a gap this long is history from before an outage, not recent subblocks
  @window_ms 15_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Stores `item`. An item with the same block number and index is replaced, unless only its arrival time differs:
  a re-sent identical subblock keeps the time it first arrived.
  """
  @spec put(Frame.item()) :: :new | :replaced | :unchanged
  def put(item), do: GenServer.call(__MODULE__, {:put, item})

  @doc """
  The buffered items in ascending `{block_number, index}` order, at most #{@max_items}. Empty when the buffer is not
  running (the relay is not configured), and while nothing has arrived for #{@stale_after_ms} ms, so that a client
  that joins during an outage is not shown old subblocks as live; items older than #{@window_ms} ms before the newest
  one are left out for the same reason.
  """
  @spec recent() :: [Frame.item()]
  def recent do
    case :ets.whereis(@table) do
      :undefined -> []
      table -> table |> :ets.tab2list() |> Enum.map(fn {_key, item} -> item end) |> unless_stale()
    end
  end

  defp unless_stale(items) do
    newest = items |> Enum.map(& &1.received_at) |> Enum.max(fn -> 0 end)

    if System.system_time(:millisecond) - newest > @stale_after_ms,
      do: [],
      else: Enum.filter(items, &(&1.received_at >= newest - @window_ms))
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:ordered_set, :named_table, :protected, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:put, item}, _from, state) do
    key = {item.block_number, item.index}

    result =
      case :ets.lookup(@table, key) do
        [] -> :new
        [{^key, stored}] -> if same_content?(stored, item), do: :unchanged, else: :replaced
      end

    if result != :unchanged do
      :ets.insert(@table, {key, item})
      trim()
    end

    {:reply, result, state}
  end

  defp same_content?(stored, item), do: Map.delete(stored, :received_at) == Map.delete(item, :received_at)

  defp trim do
    if :ets.info(@table, :size) > @max_items do
      :ets.delete(@table, :ets.first(@table))
      trim()
    end
  end
end
