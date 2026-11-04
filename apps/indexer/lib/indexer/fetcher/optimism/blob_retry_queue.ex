defmodule Indexer.Fetcher.Optimism.BlobRetryQueue do
  @moduledoc """
  Queue of L1 blocks whose EIP-4844 blob fetches exhausted all the
  sources (Primary Blobs API → Fallback Blobs API → Beacon Node blobs
  endpoint → Beacon Node sidecars).

  Common cause on Mantle Hoodi: the operator's DA indexer hasn't yet
  ingested a brand-new blob when Blockscout's batch fetcher races ahead
  to scan the L1 block. A short retry-with-backoff usually recovers the
  data once da-indexer catches up.

  Usage:

      # 1. Started under indexer supervisor (no args).
      BlobRetryQueue.start_link([])

      # 2. Enqueue when all sources exhaust:
      BlobRetryQueue.enqueue(l1_block_number, blob_hash, l1_tx_hash)

      # 3. From the main fetcher loop, before scanning new blocks:
      case BlobRetryQueue.due_min_block() do
        nil -> proceed_with_normal_start_block(state)
        block -> rewind_start_block_to(block, state)
      end

  Bounded backoff: 30s, 5min, 30min, 2h, 8h. After 5 failed attempts
  the entry is dropped and a final warning is logged so ops can act.

  The batch fetcher's checkpoint moves past a queued block, so the queue is all that brings the block back, and it
  lives in memory. Its lowest block is therefore kept in `last_fetched_counters`
  (`optimism_blob_retry_queue_min_l1_block`): written when a block is queued below it, and again when the lowest block
  leaves the queue. A block whose blobs are all recovered stays queued, only to be rescanned, until the batch fetcher
  has imported the chunk of the block and the channels it carries frames of (`mark_range_imported/3`). When the batch
  fetcher starts, `restore/0` queues the
  kept block again, due like a newly queued one: the rescan from it covers every block queued before the restart, and
  starts between two runs of the main loop, so after the catch-up of a new instance, as for a block queued during it.
  A block queued only to be rescanned (by `restore/0` or `requeue_for_rescan/1`) leaves the queue once its chunk has
  been imported: a blob still missing then was queued again under its own hash.
  """

  use Agent

  require Logger

  alias Explorer.Chain.Cache.Counters.LastFetchedCounter

  @max_attempts 5
  # seconds, indexed by attempt count (0-based, capped at @max_attempts-1)
  @backoff_seconds [30, 300, 1800, 7200, 28_800]

  # the lowest queued L1 block, kept across restarts
  @counter_type "optimism_blob_retry_queue_min_l1_block"

  # the blob and transaction hash of a block queued only to be rescanned
  @rescan_marker "rescan"

  # Queue value type:
  #   %{
  #     blob_hashes: MapSet.t(String.t()),  # one or more blobs that failed
  #     l1_tx_hashes: MapSet.t(String.t()),
  #     attempts: non_neg_integer(),
  #     last_attempt_at: integer()  # System.system_time(:second)
  #   }

  # Public API ------------------------------------------------------------

  @doc false
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Queues again the lowest block queued before a restart, due like a newly queued block: the rescan from it covers the
  other ones. Being not due at once, it does not make a restart in the middle of a catch-up scan from it again before
  the catch-up goes on. The batch fetcher calls it when it starts, so that a failed read restarts the fetcher, not the
  whole indexer.
  """
  @spec restore() :: :ok
  def restore do
    case LastFetchedCounter.get(@counter_type, nullable: true) do
      nil ->
        :ok

      value ->
        block = Decimal.to_integer(value)

        Logger.warning(
          "BlobRetryQueue: L1 block #{block} had blobs missing before the restart, so the L1 blocks from it are scanned " <>
            "again once the batch fetcher has caught up with the L1 head."
        )

        rescan = %{
          blob_hashes: MapSet.new([@rescan_marker]),
          l1_tx_hashes: MapSet.new([@rescan_marker]),
          attempts: 0,
          last_attempt_at: now()
        }

        update(:never, &Map.put_new(&1, block, rescan))
    end
  end

  @doc """
  Add a failed blob fetch to the retry queue. Idempotent — re-enqueueing
  the same `l1_block_number` merges blob/tx hashes into the existing entry
  without resetting attempt counter.
  """
  @spec enqueue(non_neg_integer(), String.t(), String.t()) :: :ok
  def enqueue(l1_block_number, blob_hash, l1_tx_hash)
      when is_integer(l1_block_number) and is_binary(blob_hash) and is_binary(l1_tx_hash) do
    # the block must be kept before the fetcher's checkpoint moves past it
    update(:if_lowered, fn state ->
      Map.update(
        state,
        l1_block_number,
        %{
          blob_hashes: MapSet.new([blob_hash]),
          l1_tx_hashes: MapSet.new([l1_tx_hash]),
          attempts: 0,
          last_attempt_at: now()
        },
        fn existing ->
          %{
            existing
            | blob_hashes: MapSet.put(existing.blob_hashes, blob_hash),
              l1_tx_hashes: MapSet.put(existing.l1_tx_hashes, l1_tx_hash)
          }
        end
      )
    end)
  end

  @doc """
  Returns the smallest L1 block number that's due for retry, or `nil` if
  none are due. The caller is expected to rewind `start_block` to this
  value (or lower) for the next scan iteration.
  """
  @spec due_min_block() :: non_neg_integer() | nil
  def due_min_block do
    if alive?(), do: Agent.get(__MODULE__, &min_due_block/1, :infinity)
  end

  @doc """
  Whether a block below `l1_block_number` is queued with a blob still missing: the batch fetcher is to rescan from it,
  so `l1_block_number` as well. A block queued only to be rescanned leaves the queue once its chunk is imported, and
  the queued `l1_block_number` itself leaves it once its blobs are recovered.
  """
  @spec missing_below?(non_neg_integer()) :: boolean()
  def missing_below?(l1_block_number) do
    alive?() and
      Agent.get(
        __MODULE__,
        &Enum.any?(&1, fn {block, info} -> block < l1_block_number and not rescan_only?(info) end),
        :infinity
      )
  end

  @doc """
  Drops the blocks of the given range queued only to be rescanned: the batch fetcher has imported the chunks of the
  range, so their batches are in, but for the frames of the channels still incomplete, which are in memory only, so
  the blocks carrying them (`pending_blocks`) stay queued. A block of the range still missing a blob stays queued too.
  """
  @spec mark_range_imported(non_neg_integer(), non_neg_integer(), MapSet.t(non_neg_integer())) :: :ok
  def mark_range_imported(l1_block_start, l1_block_end, pending_blocks \\ MapSet.new())
      when is_integer(l1_block_start) and is_integer(l1_block_end) do
    update(:if_changed, fn state ->
      Map.reject(state, fn {block, info} ->
        block >= l1_block_start and block <= l1_block_end and rescan_only?(info) and
          not MapSet.member?(pending_blocks, block)
      end)
    end)
  end

  @doc """
  Mark every entry whose `l1_block_number` is in the given range as
  attempted (increments attempts, updates last_attempt_at). Drops entries
  that have exceeded `@max_attempts` and logs a final warning. Before that, a
  block queued only to be rescanned is not dropped here but once the chunk of
  the block is imported (`mark_range_imported/3`): an L1 reorg can halt the
  rescan before.

  Should be called by the main fetcher loop AFTER it finishes rescanning
  the rewound L1 block range, regardless of success.
  """
  @spec mark_range_attempted(non_neg_integer(), non_neg_integer()) :: :ok
  def mark_range_attempted(l1_block_start, l1_block_end)
      when is_integer(l1_block_start) and is_integer(l1_block_end) do
    # the rescanned blocks are imported now, so the lowest block still queued is the one to keep
    update(:always, fn state ->
      state
      |> Enum.flat_map(&attempt_in_range(&1, l1_block_start, l1_block_end))
      |> Map.new()
    end)
  end

  @doc """
  Mark a blob as recovered. When every failed blob of the L1 block has
  recovered, the block stays queued only to be rescanned:
  `mark_range_imported/3` drops it once the chunk of the block is imported.
  """
  @spec mark_blob_succeeded(non_neg_integer(), String.t()) :: :ok
  def mark_blob_succeeded(l1_block_number, blob_hash)
      when is_integer(l1_block_number) and is_binary(blob_hash) do
    update(:never, &drop_blob(&1, l1_block_number, blob_hash))
  end

  @doc """
  Remove a specific L1 block from the queue. Call when retry succeeded
  (frame_sequence row created for that block).
  """
  @spec remove(non_neg_integer()) :: :ok
  def remove(l1_block_number) do
    update(:always, &Map.delete(&1, l1_block_number))
  end

  @doc """
  Returns the current queue size. Useful for telemetry / health checks.
  """
  @spec size() :: non_neg_integer()
  def size do
    if alive?() do
      Agent.get(__MODULE__, &map_size/1, :infinity)
    else
      0
    end
  end

  @doc """
  Returns the full snapshot for debugging/inspection.
  """
  @spec snapshot() :: map()
  def snapshot do
    if alive?() do
      Agent.get(__MODULE__, & &1, :infinity)
    else
      %{}
    end
  end

  @doc """
  Operator helper — re-enqueue an arbitrary L1 block range for re-scan.

  Use case: after seeing `GIVING UP on L1 block N` errors in production logs,
  call this from a remote IEx shell to schedule a fresh retry pass against
  the affected blocks. The next main-loop tick will pick up the smallest
  enqueued block and rewind `start_block` accordingly.

  Only the lowest block of a range or list is queued, as the rescan from it
  covers the others. It leaves the queue once rescanned; a blob still missing
  then is queued again under its own hash, and a block given up goes through a
  fresh 5-attempt backoff cycle.

  ## Example

      # Re-scan a single block
      BlobRetryQueue.requeue_for_rescan(2680123)

      # Re-scan a range
      BlobRetryQueue.requeue_for_rescan(2680000..2680999)

      # Re-scan a list of blocks (e.g. extracted from `GIVING UP` logs)
      BlobRetryQueue.requeue_for_rescan([2680123, 2685001, 2690500])
  """
  @spec requeue_for_rescan(non_neg_integer() | Range.t() | [non_neg_integer()]) :: :ok
  def requeue_for_rescan(l1_block_number) when is_integer(l1_block_number) do
    enqueue(l1_block_number, @rescan_marker, @rescan_marker)
  end

  def requeue_for_rescan(%Range{first: first, last: last}) do
    requeue_for_rescan(min(first, last))
  end

  def requeue_for_rescan([]), do: :ok

  def requeue_for_rescan(blocks) when is_list(blocks) do
    requeue_for_rescan(Enum.min(blocks))
  end

  @doc """
  Operator helper — clear the entire retry queue.

  Useful when ops are confident the affected blobs cannot be recovered
  (e.g. da-indexer permanently lost them) and want to silence the
  periodic "BlobRetryQueue: retrying L1 block ..." chatter.
  """
  @spec clear() :: :ok
  def clear do
    update(:always, fn _ -> %{} end)
  end

  # Internal helpers -------------------------------------------------------

  # Applies `fun` to the queue and keeps its lowest block in `last_fetched_counters`: `:always`, `:if_lowered` (when
  # `fun` lowers it, or queues a first block), `:if_changed` or `:never`. A DB call can take longer than the default 5
  # seconds of an Agent call, which would crash the fetcher, so the calls wait like the fetcher's imports do.
  defp update(keep, fun) do
    if alive?() do
      case Agent.get_and_update(__MODULE__, &apply_and_keep(&1, fun, keep), :infinity) do
        :ok -> :ok
        {:error, error} -> raise "BlobRetryQueue: cannot keep the lowest queued L1 block. Reason: #{inspect(error)}"
      end
    else
      :ok
    end
  end

  # a recovered blob, once per fetched blob: no need to look for the lowest block
  defp apply_and_keep(state, fun, :never), do: {:ok, fun.(state)}

  defp apply_and_keep(state, fun, keep) do
    new_state = fun.(state)
    min_block = min_block(new_state)

    cond do
      # The block must be kept before the fetcher's checkpoint moves past it: a failed write leaves the queue as it was
      # and fails the caller, so that the fetcher restarts and scans the block again.
      keep == :if_lowered and min_block != min_block(state) ->
        case keep_min_block(min_block) do
          :ok -> {:ok, new_state}
          error -> {error, state}
        end

      # a failed write keeps a lower block, so a restart only rescans more
      keep == :always or (keep == :if_changed and min_block != min_block(state)) ->
        keep_min_block(min_block)
        {:ok, new_state}

      true ->
        {:ok, new_state}
    end
  end

  defp keep_min_block(block) do
    if is_nil(block),
      do: LastFetchedCounter.delete(@counter_type),
      else: {:ok, _} = LastFetchedCounter.upsert(%{counter_type: @counter_type, value: block})

    :ok
  rescue
    error ->
      Logger.warning(
        "BlobRetryQueue: cannot keep the lowest queued L1 block (#{inspect(block)}). Reason: #{inspect(error)}"
      )

      {:error, error}
  end

  defp min_block(state) when map_size(state) == 0, do: nil
  defp min_block(state), do: state |> Map.keys() |> Enum.min()

  defp min_due_block(state) do
    state
    |> Enum.filter(fn {_block, info} -> ready_for_retry?(info) end)
    |> Enum.map(fn {block, _info} -> block end)
    |> Enum.min(fn -> nil end)
  end

  defp attempt_in_range({block, info}, l1_block_start, l1_block_end)
       when block >= l1_block_start and block <= l1_block_end do
    info
    |> Map.merge(%{attempts: info.attempts + 1, last_attempt_at: now()})
    |> keep_after_attempt(block)
  end

  defp attempt_in_range(entry, _l1_block_start, _l1_block_end), do: [entry]

  # The block of the last recovered blob stays queued to be rescanned: its batches are not imported yet, so the lowest
  # queued block must not move above it.
  defp drop_blob(state, l1_block_number, blob_hash) do
    case Map.fetch(state, l1_block_number) do
      :error ->
        state

      {:ok, info} ->
        blob_hashes = MapSet.delete(info.blob_hashes, blob_hash)
        blob_hashes = if MapSet.size(blob_hashes) == 0, do: MapSet.new([@rescan_marker]), else: blob_hashes

        Map.put(state, l1_block_number, %{info | blob_hashes: blob_hashes})
    end
  end

  defp keep_after_attempt(%{blob_hashes: blob_hashes} = info, block) do
    if info.attempts >= @max_attempts do
      Logger.error(
        "BlobRetryQueue: GIVING UP on L1 block #{block} after #{@max_attempts} attempts. " <>
          "Affected blobs: #{inspect(blob_hashes |> MapSet.delete(@rescan_marker) |> MapSet.to_list())}, " <>
          "L1 txs: #{inspect(info.l1_tx_hashes |> MapSet.delete(@rescan_marker) |> MapSet.to_list())}. " <>
          "These channels' L2 batches will remain unbatched — manual recovery required " <>
          "(rewind INDEXER_OPTIMISM_L1_START_BLOCK or re-run the fetcher against this L1 range)."
      )

      []
    else
      [{block, info}]
    end
  end

  defp rescan_only?(%{blob_hashes: blob_hashes}), do: MapSet.equal?(blob_hashes, MapSet.new([@rescan_marker]))

  defp ready_for_retry?(%{attempts: attempts, last_attempt_at: last}) do
    backoff = Enum.at(@backoff_seconds, min(attempts, @max_attempts - 1))
    now() - last >= backoff
  end

  defp now, do: System.system_time(:second)

  defp alive?, do: Process.whereis(__MODULE__) != nil
end
