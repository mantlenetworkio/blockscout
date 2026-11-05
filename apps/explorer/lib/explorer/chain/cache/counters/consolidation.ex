# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Chain.Cache.Counters.Consolidation do
  @moduledoc """
  Plumbing shared by the incremental counter consolidators
  (`Explorer.Chain.Cache.Counters.AddressCountersConsolidator` and
  `Explorer.Chain.Cache.Counters.TokenCountersConsolidator`):

  * `safe_block/0` — the highest block number consolidated ranges may cover;
  * `settle_pending_refetch_blocks/0` — applies the pending positive counter
    corrections for re-fetched blocks (see `Explorer.Utility.CountersRefetchBlock`)
    to both the address and the token counters.

  Both consolidators call the settle at the start of their cycles; a
  transaction-scoped advisory lock guarantees the corrections are applied
  exactly once even when the cycles overlap.
  """

  import Ecto.Query

  require Logger

  alias EthereumJSONRPC.Utility.RangesHelper
  alias Explorer.Chain.{Block, TokenTransfer, Transaction}
  alias Explorer.Chain.Cache.BlockNumber
  alias Explorer.Chain.Cache.Counters.{AddressCounters, AddressCountersConsolidator, LastFetchedCounter, TokenCounters}
  alias Explorer.Chain.Cache.Counters.TokenCountersConsolidator
  alias Explorer.Repo
  alias Explorer.Utility.{CountersRefetchBlock, MassiveBlock, MissingBlockRange}

  @refetch_blocks_chunk_size 100

  # the highest block up to which `safe_block/0` found a consensus block at
  # every number
  @contiguous_block_counter_type "counters_consolidation_contiguous_block"

  # arbitrary constant identifying the settle critical section among
  # `pg_advisory_xact_lock` users
  @settle_advisory_lock_key 7_235_622_386_001

  @doc """
  Returns the highest block number consolidated ranges may currently cover or
  `nil` when consolidation is not possible yet: the chain head minus the
  configured safety lag, additionally capped below the lowest missing block
  range, the lowest massive block, the lowest block pending a re-fetch counter
  correction and the first block number without a consensus block in the
  database.

  While the chain is not yet indexed down to the configured first block —
  initial backward sync, before the missing ranges collector has recorded the
  unindexed tail — no safe block exists at all: consolidating past blocks that
  are absent but not yet registered in `missing_block_ranges` would lose their
  contributions forever.

  Blocks below the chain head also go missing unregistered for a while later
  on: after a restart the realtime fetcher imports the new chain head before
  the missing ranges collector registers the downtime gap, and a block the
  realtime fetcher fails to import waits for the next scan of the collector.
  So the safe block also stays below the first block number above the last
  checked one that has no consensus block. The checked number is stored, so a
  call checks only the blocks added since, at most `contiguity_window` of them.
  The first call trusts the chain up to the last completed scan of the missing
  ranges collector (up to the lagged chain head before any), as the gaps
  registered below keep their own caps. Chains indexed in block ranges other
  than a single one open to the latest block, and Filecoin chains, whose null
  rounds have no block, are not checked.
  """
  @spec safe_block() :: non_neg_integer() | nil
  def safe_block do
    if lower_chain_indexed?() do
      lagged_head = lagged_head()

      [lagged_head, min_missing_block_cap(), min_massive_block_cap(), min_pending_refetch_cap()]
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)
      |> contiguous_cap(lagged_head)
      |> case do
        safe_block when is_integer(safe_block) and safe_block > 0 -> safe_block
        _ -> nil
      end
    end
  end

  @doc """
  Returns `true` when `safe_block` is below the lagged chain head, capped by a
  missing block range, a massive block, a block pending a re-fetch counter
  correction or a block number without a consensus block.

  A recalculation from scratch (a `NULL` watermark) stored at a capped safe
  block would leave the rows above the cap to no dirty marker (an import marks
  only the rows it brings), and the address or token would keep the counters
  of the capped range until its next activity. So the consolidators leave
  `NULL` watermarks alone and the backfills wait while the safe block is
  capped. A block that arrives between `safe_block/0` and this check only
  delays them by one round.
  """
  @spec capped?(non_neg_integer()) :: boolean()
  def capped?(safe_block) do
    case lagged_head() do
      head when is_integer(head) -> safe_block < head
      _ -> false
    end
  end

  @doc """
  Returns the configured number of blocks the consolidation watermarks stay
  behind the chain head.
  """
  @spec safe_block_lag() :: non_neg_integer()
  def safe_block_lag do
    Application.get_env(:explorer, __MODULE__)[:safe_block_lag] || 12
  end

  @doc """
  Settles the pending block re-fetch corrections: for every queued block whose
  re-fetch fully completed, adds the counter contributions of the re-imported
  content back to the addresses and tokens whose watermarks already cover the
  block, then drops the queue rows. Blocks whose re-import is still in flight
  (the consensus block still requires a re-fetch, or the block is still
  covered by a missing range or a massive block) are left queued. Returns `:failed` when the
  settlement failed (it is retried by a later cycle).
  """
  @spec settle_pending_refetch_blocks() :: :ok | :failed
  def settle_pending_refetch_blocks do
    case Repo.all(ready_to_settle_query(), timeout: query_timeout()) do
      [] ->
        :ok

      block_numbers ->
        case settle_refetched_blocks(block_numbers) do
          # another settle is in progress on this or another node
          :skipped -> :ok
          # more rows may be ready
          :ok -> settle_pending_refetch_blocks()
        end
    end
  rescue
    error ->
      Logger.error(fn ->
        ["Failed to settle re-fetched blocks counters: ", Exception.format(:error, error, __STACKTRACE__)]
      end)

      :failed
  end

  # a block is ready to settle once its re-fetch completed: the consensus
  # block no longer requires a re-fetch AND the block is no longer covered
  # by a missing range (the range row survives until the whole re-import —
  # all its stages — succeeded, so old content can no longer be observed) and
  # no longer a massive block (a re-import that timed out moves the range
  # there, and the row survives in the same way, see `min_massive_block_cap/0`)
  defp ready_to_settle_query do
    from(refetch_block in CountersRefetchBlock,
      as: :refetch_block,
      where:
        not exists(
          from(block in Block,
            where:
              block.number == parent_as(:refetch_block).block_number and block.consensus == true and
                block.refetch_needed == true,
            select: 1
          )
        ),
      where:
        not exists(
          from(range in MissingBlockRange,
            where:
              range.from_number >= parent_as(:refetch_block).block_number and
                range.to_number <= parent_as(:refetch_block).block_number,
            select: 1
          )
        ),
      where:
        not exists(
          from(massive_block in MassiveBlock,
            where: massive_block.number == parent_as(:refetch_block).block_number,
            select: 1
          )
        ),
      select: refetch_block.block_number,
      limit: @refetch_blocks_chunk_size
    )
  end

  defp settle_refetched_blocks(block_numbers) do
    {:ok, result} =
      Repo.transaction(
        fn ->
          if advisory_lock_acquired?() do
            transactions =
              Repo.all(
                from(transaction in Transaction,
                  where: transaction.block_number in ^block_numbers,
                  select: struct(transaction, [:block_number, :from_address_hash, :to_address_hash, :gas_used])
                ),
                timeout: query_timeout()
              )

            token_transfers =
              Repo.all(
                from(token_transfer in TokenTransfer,
                  where: token_transfer.block_number in ^block_numbers,
                  select:
                    struct(token_transfer, [
                      :block_number,
                      :from_address_hash,
                      :to_address_hash,
                      :token_contract_address_hash
                    ])
                ),
                timeout: query_timeout()
              )

            updated_address_bytes =
              AddressCountersConsolidator.apply_covered_deltas(transactions, token_transfers, :positive)

            updated_token_bytes = TokenCountersConsolidator.apply_covered_transfer_deltas(token_transfers, :positive)

            CountersRefetchBlock.delete_by_block_numbers(Enum.sort(block_numbers))

            {updated_address_bytes, updated_token_bytes}
          else
            :skipped
          end
        end,
        timeout: :infinity
      )

    case result do
      :skipped ->
        :skipped

      {updated_address_bytes, updated_token_bytes} ->
        AddressCounters.invalidate(updated_address_bytes)
        TokenCounters.invalidate(updated_token_bytes)
        :ok
    end
  end

  defp advisory_lock_acquired? do
    %{rows: [[acquired]]} = Repo.query!("SELECT pg_try_advisory_xact_lock($1)", [@settle_advisory_lock_key])

    acquired
  end

  defp lower_chain_indexed? do
    first_block = Application.get_env(:indexer, :first_block)

    case BlockNumber.get_min() do
      min_block_number when is_integer(min_block_number) -> min_block_number <= first_block
      _ -> false
    end
  end

  defp lagged_head do
    case BlockNumber.get_max() do
      max_block_number when is_integer(max_block_number) -> max_block_number - safe_block_lag()
      _ -> nil
    end
  end

  defp min_missing_block_cap do
    case MissingBlockRange.fetch_min_max() do
      %{min: min} when is_integer(min) -> min - 1
      _ -> nil
    end
  end

  # A catchup import that timed out moves its range from the missing block
  # ranges to the massive blocks, and the block fetchers defer a block with more
  # transactions than `massive_block_threshold` there too.
  # `Indexer.Block.Catchup.MassiveBlocksFetcher` deletes a row only once it
  # imported the block in full: an import commits the block before its
  # transactions, so a present block is not enough.
  defp min_massive_block_cap do
    case Repo.aggregate(MassiveBlock, :min, :number, timeout: query_timeout()) do
      number when is_integer(number) -> number - 1
      _ -> nil
    end
  end

  defp min_pending_refetch_cap do
    case CountersRefetchBlock.min_block_number() do
      block_number when is_integer(block_number) -> block_number - 1
      _ -> nil
    end
  end

  # see `safe_block/0`
  defp contiguous_cap(safe_block, lagged_head) when is_integer(safe_block) and safe_block > 0 do
    if contiguity_checked?(), do: cap_at_contiguous_block(safe_block, lagged_head), else: safe_block
  end

  defp contiguous_cap(safe_block, _lagged_head), do: safe_block

  defp cap_at_contiguous_block(safe_block, lagged_head) do
    case contiguous_block() do
      nil ->
        trusted = first_trusted_block(lagged_head || safe_block)
        store_contiguous_block(trusted)
        if trusted >= safe_block, do: safe_block, else: check_contiguity(trusted, safe_block)

      checked when checked >= safe_block ->
        safe_block

      checked ->
        check_contiguity(checked, safe_block)
    end
  end

  # The first call trusts the chain up to the boundary of the last completed
  # scan of the missing ranges collector, which registered every gap below it,
  # or up to the lagged chain head while no scan has completed. The gaps
  # registered below keep their own caps.
  defp first_trusted_block(lagged_head) do
    case MissingBlockRange.initial_scan_boundary() do
      boundary when is_integer(boundary) -> min(boundary, lagged_head)
      nil -> lagged_head
    end
  end

  defp contiguity_checked? do
    Application.get_env(:explorer, :chain_type) != :filecoin and open_block_range?()
  end

  # catchup fills the gaps up to the chain head only for a single block range
  # open to the latest block, the default ("<FIRST_BLOCK>..latest")
  defp open_block_range? do
    case Application.get_env(:indexer, :block_ranges) do
      block_ranges when is_binary(block_ranges) ->
        match?([first_block] when is_integer(first_block), RangesHelper.parse_block_ranges(block_ranges))

      _ ->
        true
    end
  end

  defp check_contiguity(checked, safe_block) do
    to = min(safe_block, checked + contiguity_window())

    contiguous =
      case first_number_without_consensus_block(checked + 1, to) do
        nil -> to
        number -> number - 1
      end

    if contiguous > checked, do: store_contiguous_block(contiguous)

    contiguous
  end

  # An anti join against the range of the `one_consensus_block_at_height` index.
  # The bound on `blocks.number` repeats what the join implies: without it the
  # planner may hash every consensus block of the chain.
  defp first_number_without_consensus_block(from, to) do
    %{rows: [[number]]} =
      Repo.query!(
        """
        SELECT min(series.number)
        FROM generate_series($1::bigint, $2::bigint) AS series(number)
        WHERE NOT EXISTS (
          SELECT 1 FROM blocks
          WHERE blocks.number = series.number AND blocks.number BETWEEN $1 AND $2 AND blocks.consensus
        )
        """,
        [from, to],
        timeout: query_timeout()
      )

    number
  end

  defp store_contiguous_block(block_number) do
    LastFetchedCounter.upsert_max(%{counter_type: @contiguous_block_counter_type, value: block_number})
  end

  defp contiguous_block do
    case LastFetchedCounter.get(@contiguous_block_counter_type, nullable: true) do
      nil -> nil
      value -> Decimal.to_integer(value)
    end
  end

  defp contiguity_window do
    Application.get_env(:explorer, __MODULE__)[:contiguity_window] || 100_000
  end

  defp query_timeout do
    Application.get_env(:explorer, __MODULE__)[:query_timeout] || :timer.minutes(5)
  end
end
