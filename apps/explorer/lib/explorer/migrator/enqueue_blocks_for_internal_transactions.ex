# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Migrator.EnqueueBlocksForInternalTransactions do
  @moduledoc """
  Queues the never traced blocks of a configured block range for
  `Indexer.Fetcher.InternalTransaction`.

  The import queues a block for tracing only if the block is inside the trace
  range (`TRACE_FIRST_BLOCK`, `TRACE_LAST_BLOCK`, `TRACE_BLOCK_RANGES`).
  Widening the range later does not queue the blocks imported before, so their
  internal transactions are never fetched. This migration queues every consensus
  block of `first_block..last_block` with a transaction whose
  `has_error_in_internal_transactions` is still `nil`, i.e. a transaction that
  was never traced. It inserts a pending block operation for such a block, or a
  pending transaction operation for each such transaction when internal
  transactions are fetched by transaction.

  The fetcher skips the operations outside the trace range until the range
  covers them; until then they also count as pending, e.g. for the indexing
  status of the `txlistinternal` API. Run the migration on an imported range
  below the reorg depth: on a database without blocks it completes at once. It
  waits for the migrations that fill and fix `transactions.block_consensus`.

  The migration processes the range in ascending batches and persists its
  progress, so it runs to completion only once. To re-run it, delete the
  "enqueue_blocks_for_internal_transactions" record from the `migrations_status`
  table.
  """

  use Explorer.Migrator.FillingMigration

  import Ecto.Query

  alias Explorer.Chain.{PendingBlockOperation, PendingOperationsHelper, PendingTransactionOperation, Transaction}
  alias Explorer.Migrator.{FillingMigration, TransactionBlockConsensus, TransactionsDenormalization}
  alias Explorer.Repo
  alias Indexer.Fetcher.InternalTransaction, as: InternalTransactionFetcher

  @migration_name "enqueue_blocks_for_internal_transactions"

  @impl FillingMigration
  def migration_name, do: @migration_name

  # The query below selects transactions by `transactions.block_consensus`.
  @impl FillingMigration
  def dependent_from_migrations,
    do: [TransactionsDenormalization.migration_name(), TransactionBlockConsensus.migration_name()]

  @impl FillingMigration
  def last_unprocessed_identifiers(%{"next_block_number" => from_block_number} = state) do
    last_block_number = Application.get_env(:explorer, __MODULE__)[:last_block]

    if from_block_number > last_block_number do
      {[], state}
    else
      to_block_number = min(from_block_number + batch_size() * concurrency() - 1, last_block_number)

      {Enum.to_list(from_block_number..to_block_number), %{state | "next_block_number" => to_block_number + 1}}
    end
  end

  def last_unprocessed_identifiers(state) do
    state
    |> Map.put("next_block_number", Application.get_env(:explorer, __MODULE__)[:first_block])
    |> last_unprocessed_identifiers()
  end

  @impl FillingMigration
  def unprocessed_data_query, do: nil

  @impl FillingMigration
  def update_batch(block_numbers) do
    {from_block_number, to_block_number} = Enum.min_max(block_numbers)

    from_block_number
    |> untraced_transactions(to_block_number)
    |> enqueue()
  end

  @impl FillingMigration
  def update_cache, do: :ok

  defp untraced_transactions(from_block_number, to_block_number) do
    Transaction
    |> where([t], t.block_number >= ^from_block_number and t.block_number <= ^to_block_number)
    |> where([t], t.block_consensus == true and is_nil(t.has_error_in_internal_transactions))
    |> select([t], %{hash: t.hash, block_hash: t.block_hash, block_number: t.block_number, index: t.index, type: t.type})
    |> Repo.all(timeout: :infinity)
    |> Transaction.filter_non_traceable_transactions()
  end

  defp enqueue([]), do: :ok

  defp enqueue(transactions) do
    now = DateTime.utc_now()

    case PendingOperationsHelper.pending_operations_type() do
      "blocks" ->
        params =
          transactions
          |> Enum.uniq_by(& &1.block_hash)
          # Enforce ShareLocks order (see docs: sharelocks.md)
          |> Enum.sort_by(& &1.block_hash.bytes)
          |> Enum.map(&%{block_hash: &1.block_hash, block_number: &1.block_number, inserted_at: now, updated_at: now})

        {_count, inserted} =
          Repo.safe_insert_all(PendingBlockOperation, params, on_conflict: :nothing, returning: [:block_number])

        async_fetch(Enum.map(inserted, & &1.block_number), [])

      "transactions" ->
        params =
          transactions
          # Enforce ShareLocks order (see docs: sharelocks.md)
          |> Enum.sort_by(& &1.hash.bytes)
          |> Enum.map(&%{transaction_hash: &1.hash, inserted_at: now, updated_at: now})

        {_count, inserted} =
          Repo.safe_insert_all(PendingTransactionOperation, params,
            on_conflict: :nothing,
            returning: [:transaction_hash]
          )

        inserted_hashes = MapSet.new(inserted, & &1.transaction_hash)

        async_fetch([], Enum.filter(transactions, &MapSet.member?(inserted_hashes, &1.hash)))
    end
  end

  defp async_fetch(block_numbers, transactions) do
    if Process.whereis(InternalTransactionFetcher) do
      InternalTransactionFetcher.async_fetch(block_numbers, transactions, false)
    end

    :ok
  end
end
