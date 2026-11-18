# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Migrator.EnqueueBlocksForInternalTransactionsTest do
  use Explorer.DataCase, async: false

  alias Explorer.Chain.{Block, PendingBlockOperation, PendingTransactionOperation, Transaction}
  alias Explorer.Migrator.{EnqueueBlocksForInternalTransactions, MigrationStatus}
  alias Explorer.Repo

  @migration_name "enqueue_blocks_for_internal_transactions"

  setup do
    initial_config = Application.get_env(:explorer, EnqueueBlocksForInternalTransactions)

    # 7 blocks in batches of 2, so the last batch holds a single block
    Application.put_env(
      :explorer,
      EnqueueBlocksForInternalTransactions,
      Keyword.merge(initial_config || [], first_block: 10, last_block: 16, batch_size: 2, concurrency: 1)
    )

    geth_config = Application.get_env(:ethereum_jsonrpc, EthereumJSONRPC.Geth)
    json_rpc_named_arguments = Application.get_env(:explorer, :json_rpc_named_arguments)

    Application.put_env(
      :explorer,
      :json_rpc_named_arguments,
      Keyword.merge(json_rpc_named_arguments, variant: EthereumJSONRPC.Geth)
    )

    on_exit(fn ->
      Application.put_env(:explorer, EnqueueBlocksForInternalTransactions, initial_config || [])
      Application.put_env(:ethereum_jsonrpc, EthereumJSONRPC.Geth, geth_config)
      Application.put_env(:explorer, :json_rpc_named_arguments, json_rpc_named_arguments)
    end)

    # the migration reads `transactions.block_consensus`, which these migrations fill and fix
    MigrationStatus.set_status("denormalization", "completed")
    MigrationStatus.set_status("transactions_block_consensus", "completed")

    %{geth_config: geth_config}
  end

  describe "before the transactions consensus flags are complete" do
    setup %{geth_config: geth_config} do
      Application.put_env(:ethereum_jsonrpc, EthereumJSONRPC.Geth, Keyword.merge(geth_config, block_traceable?: true))

      heavy_index_config = Application.get_env(:explorer, Explorer.Migrator.HeavyDbIndexOperation)

      Application.put_env(
        :explorer,
        Explorer.Migrator.HeavyDbIndexOperation,
        Keyword.merge(heavy_index_config || [], check_interval: 50)
      )

      on_exit(fn ->
        Application.put_env(:explorer, Explorer.Migrator.HeavyDbIndexOperation, heavy_index_config || [])
      end)
    end

    test "waits for the migrations that fill transactions.block_consensus" do
      insert_block_with_untraced_transaction(10)
      MigrationStatus.set_status("denormalization", "started")

      EnqueueBlocksForInternalTransactions.start_link([])
      Process.sleep(500)

      assert [] == queued_block_numbers()
      refute MigrationStatus.get_status(@migration_name) == "completed"

      MigrationStatus.set_status("denormalization", "completed")
      wait_for_completion()

      assert [10] == queued_block_numbers()
    end
  end

  describe "when internal transactions are traced by block" do
    setup %{geth_config: geth_config} do
      Application.put_env(:ethereum_jsonrpc, EthereumJSONRPC.Geth, Keyword.merge(geth_config, block_traceable?: true))
    end

    test "queues the consensus blocks of the range that have a never traced transaction" do
      insert_block_with_untraced_transaction(9)
      insert_block_with_untraced_transaction(10)

      block_11 = insert_block_with_untraced_transaction(11)
      insert(:pending_block_operation, block_hash: block_11.hash, block_number: 11)

      insert(:block, number: 12)

      13 |> insert_block_with_untraced_transaction() |> set_has_error_in_internal_transactions(false)

      block_14 = insert(:block, number: 14)
      :transaction |> insert(has_error_in_internal_transactions: true) |> with_block(block_14, status: :ok)
      :transaction |> insert() |> with_block(block_14, status: :ok)

      15 |> insert_block_with_untraced_transaction() |> lose_consensus()

      insert_block_with_untraced_transaction(16)
      insert_block_with_untraced_transaction(17)

      EnqueueBlocksForInternalTransactions.start_link([])
      wait_for_completion()

      assert [10, 11, 14, 16] == queued_block_numbers()
    end

    test "resumes from the saved progress" do
      Enum.each(10..16, &insert_block_with_untraced_transaction/1)

      MigrationStatus.set_status(@migration_name, "started")
      MigrationStatus.update_meta(@migration_name, %{"next_block_number" => 14})

      EnqueueBlocksForInternalTransactions.start_link([])
      wait_for_completion()

      assert [14, 15, 16] == queued_block_numbers()
    end
  end

  describe "when internal transactions are traced by transaction" do
    setup %{geth_config: geth_config} do
      Application.put_env(:ethereum_jsonrpc, EthereumJSONRPC.Geth, Keyword.merge(geth_config, block_traceable?: false))
    end

    test "queues the never traced transactions of the range" do
      insert_block_with_untraced_transaction(9)

      block_10 = insert(:block, number: 10)
      :transaction |> insert(has_error_in_internal_transactions: false) |> with_block(block_10, status: :ok)
      %Transaction{hash: untraced_hash_10} = :transaction |> insert() |> with_block(block_10, status: :ok)

      block_11 = insert(:block, number: 11)
      %Transaction{hash: untraced_hash_11} = :transaction |> insert() |> with_block(block_11, status: :ok)

      EnqueueBlocksForInternalTransactions.start_link([])
      wait_for_completion()

      assert Enum.sort([untraced_hash_10, untraced_hash_11]) ==
               PendingTransactionOperation |> Repo.all() |> Enum.map(& &1.transaction_hash) |> Enum.sort()

      assert [] == Repo.all(PendingBlockOperation)
    end
  end

  defp insert_block_with_untraced_transaction(number) do
    block = insert(:block, number: number)
    :transaction |> insert() |> with_block(block, status: :ok)
    block
  end

  defp set_has_error_in_internal_transactions(%Block{hash: block_hash}, value) do
    Repo.update_all(from(t in Transaction, where: t.block_hash == ^block_hash),
      set: [has_error_in_internal_transactions: value]
    )
  end

  defp lose_consensus(%Block{hash: block_hash}) do
    Repo.update_all(from(b in Block, where: b.hash == ^block_hash), set: [consensus: false])
    Repo.update_all(from(t in Transaction, where: t.block_hash == ^block_hash), set: [block_consensus: false])
  end

  defp queued_block_numbers do
    PendingBlockOperation
    |> Repo.all()
    |> Enum.map(& &1.block_number)
    |> Enum.sort()
  end

  defp wait_for_completion(retries \\ 50)

  defp wait_for_completion(0), do: flunk("migration #{@migration_name} did not complete")

  defp wait_for_completion(retries) do
    if MigrationStatus.get_status(@migration_name) == "completed" do
      :ok
    else
      Process.sleep(100)
      wait_for_completion(retries - 1)
    end
  end
end
