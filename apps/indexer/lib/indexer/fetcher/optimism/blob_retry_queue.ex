defmodule Indexer.Fetcher.Optimism.BlobRetryQueue do
  @moduledoc """
  In-memory queue of L1 blocks whose EIP-4844 blob fetches exhausted all
  three fallback sources (Primary Blobs API → Fallback Blobs API → Beacon
  Node sidecars).

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

  This is intentionally **in-memory only** — restart loses the queue.
  Tradeoff favours zero schema changes; if persistence is needed later,
  swap the underlying state for an Ecto schema (see comments in module).
  """

  use Agent

  require Logger

  @max_attempts 5
  # seconds, indexed by attempt count (0-based, capped at @max_attempts-1)
  @backoff_seconds [30, 300, 1800, 7200, 28_800]

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
  Add a failed blob fetch to the retry queue. Idempotent — re-enqueueing
  the same `l1_block_number` merges blob/tx hashes into the existing entry
  without resetting attempt counter.
  """
  @spec enqueue(non_neg_integer(), String.t(), String.t()) :: :ok
  def enqueue(l1_block_number, blob_hash, l1_tx_hash)
      when is_integer(l1_block_number) and is_binary(blob_hash) and is_binary(l1_tx_hash) do
    if alive?() do
      Agent.update(__MODULE__, fn state ->
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

    :ok
  end

  @doc """
  Returns the smallest L1 block number that's due for retry, or `nil` if
  none are due. The caller is expected to rewind `start_block` to this
  value (or lower) for the next scan iteration.
  """
  @spec due_min_block() :: non_neg_integer() | nil
  def due_min_block do
    if alive?() do
      Agent.get(__MODULE__, fn state ->
        state
        |> Enum.filter(fn {_block, info} -> ready_for_retry?(info) end)
        |> Enum.map(fn {block, _info} -> block end)
        |> case do
          [] -> nil
          blocks -> Enum.min(blocks)
        end
      end)
    end
  end

  @doc """
  Mark every entry whose `l1_block_number` is in the given range as
  attempted (increments attempts, updates last_attempt_at). Drops entries
  that have exceeded `@max_attempts` and logs a final warning.

  Should be called by the main fetcher loop AFTER it finishes rescanning
  the rewound L1 block range, regardless of success.
  """
  @spec mark_range_attempted(non_neg_integer(), non_neg_integer()) :: :ok
  def mark_range_attempted(l1_block_start, l1_block_end)
      when is_integer(l1_block_start) and is_integer(l1_block_end) do
    if alive?() do
      Agent.update(__MODULE__, fn state ->
        state
        |> Enum.flat_map(fn {block, info} ->
          if block >= l1_block_start and block <= l1_block_end do
            updated = %{info | attempts: info.attempts + 1, last_attempt_at: now()}

            if updated.attempts >= @max_attempts do
              Logger.error(
                "BlobRetryQueue: GIVING UP on L1 block #{block} after #{@max_attempts} attempts. " <>
                  "Affected blobs: #{inspect(MapSet.to_list(info.blob_hashes))}, " <>
                  "L1 txs: #{inspect(MapSet.to_list(info.l1_tx_hashes))}. " <>
                  "These channels' L2 batches will remain unbatched — manual recovery required " <>
                  "(rewind INDEXER_OPTIMISM_L1_START_BLOCK or re-run the fetcher against this L1 range)."
              )

              []
            else
              [{block, updated}]
            end
          else
            [{block, info}]
          end
        end)
        |> Map.new()
      end)
    end

    :ok
  end

  @doc """
  Mark a blob as recovered. The queue entry is removed only after all
  previously failed blobs for that L1 block have recovered.
  """
  @spec mark_blob_succeeded(non_neg_integer(), String.t()) :: :ok
  def mark_blob_succeeded(l1_block_number, blob_hash)
      when is_integer(l1_block_number) and is_binary(blob_hash) do
    if alive?() do
      Agent.update(__MODULE__, fn state ->
        case Map.fetch(state, l1_block_number) do
          :error ->
            state

          {:ok, info} ->
            blob_hashes = MapSet.delete(info.blob_hashes, blob_hash)

            if MapSet.size(blob_hashes) == 0 do
              Map.delete(state, l1_block_number)
            else
              Map.put(state, l1_block_number, %{info | blob_hashes: blob_hashes})
            end
        end
      end)
    end

    :ok
  end

  @doc """
  Remove a specific L1 block from the queue. Call when retry succeeded
  (frame_sequence row created for that block).
  """
  @spec remove(non_neg_integer()) :: :ok
  def remove(l1_block_number) do
    if alive?() do
      Agent.update(__MODULE__, &Map.delete(&1, l1_block_number))
    end

    :ok
  end

  @doc """
  Returns the current queue size. Useful for telemetry / health checks.
  """
  @spec size() :: non_neg_integer()
  def size do
    if alive?() do
      Agent.get(__MODULE__, &map_size/1)
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
      Agent.get(__MODULE__, & &1)
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

  Each enqueued block goes through a fresh 5-attempt backoff cycle.

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
    enqueue(l1_block_number, "manual_rescan", "manual_rescan")
  end

  def requeue_for_rescan(%Range{first: first, last: last}) do
    Enum.each(first..last, &requeue_for_rescan/1)
  end

  def requeue_for_rescan(blocks) when is_list(blocks) do
    Enum.each(blocks, &requeue_for_rescan/1)
  end

  @doc """
  Operator helper — clear the entire retry queue.

  Useful when ops are confident the affected blobs cannot be recovered
  (e.g. da-indexer permanently lost them) and want to silence the
  periodic "BlobRetryQueue: retrying L1 block ..." chatter.
  """
  @spec clear() :: :ok
  def clear do
    if alive?(), do: Agent.update(__MODULE__, fn _ -> %{} end)
    :ok
  end

  # Internal helpers -------------------------------------------------------

  defp ready_for_retry?(%{attempts: attempts, last_attempt_at: last}) do
    backoff = Enum.at(@backoff_seconds, min(attempts, @max_attempts - 1))
    now() - last >= backoff
  end

  defp now, do: System.system_time(:second)

  defp alive?, do: Process.whereis(__MODULE__) != nil
end
