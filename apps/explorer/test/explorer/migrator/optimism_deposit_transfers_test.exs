defmodule Explorer.Migrator.OptimismDepositTransfersTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use Explorer.DataCase, async: false

    import Explorer.OptimismBridgeFixtures

    alias Explorer.Chain.{Address, Hash}
    alias Explorer.Chain.Cache.BackgroundMigrations
    alias Explorer.Chain.Optimism.Deposit
    alias Explorer.Migrator.{MigrationStatus, OptimismDepositTransfers}

    @migration_name "optimism_deposit_transfers"
    @l2_messenger "0x4200000000000000000000000000000000000007"

    setup do
      configure_bridges()
      previous = Application.get_env(:explorer, OptimismDepositTransfers)
      put_migration_env(retries: 3)

      on_exit(fn ->
        Application.put_env(:explorer, OptimismDepositTransfers, previous)
        BackgroundMigrations.set_optimism_deposit_transfers_finished(false)
      end)
    end

    test "decodes the deposits indexed before B1 from their L2 transactions" do
      deposits =
        for name <- [:eth, :mnt, :erc20, :message] do
          fixture = deposit(name)

          {name,
           insert_op_deposit_with_message(
             from: fixture["l2_transaction_from"],
             calldata: fixture["l2_transaction_input"]
           )}
        end

      run_migration()

      for {name, row} <- deposits do
        assert stored_transfer(Repo.get!(Deposit, row.l2_transaction_hash)) == expected_transfer(deposit(name))
      end

      assert MigrationStatus.get_status(@migration_name) == "completed"
      assert BackgroundMigrations.get_optimism_deposit_transfers_finished()
    end

    # No block exists when the migration starts, as on a fresh install where L1 deposits are indexed before the
    # first L2 block: an empty `blocks` table must not complete the migration with the deposit still undecoded
    test "a deposit whose L2 transaction is indexed while the migration waits is decoded" do
      put_migration_env(retries: 100)
      fixture = deposit(:eth)
      l2_transaction_hash = insert_deposit_without_transaction()

      OptimismDepositTransfers.start_link([])
      Process.sleep(100)

      :transaction
      |> insert(
        hash: l2_transaction_hash,
        from_address: get_address(fixture["l2_transaction_from"]),
        to_address: get_address(@l2_messenger),
        input: fixture["l2_transaction_input"]
      )
      |> with_block(insert(:block), status: :ok)

      wait_for_completion()

      assert stored_transfer(Repo.get!(Deposit, l2_transaction_hash)) == expected_transfer(fixture)
    end

    test "decodes every deposit whose L2 transaction is indexed during a wait, however many batches that takes" do
      put_migration_env(retries: 1, retry_interval: 300)
      fixture = deposit(:eth)
      l2_transaction_hashes = for _ <- 1..7, do: insert_deposit_without_transaction()

      OptimismDepositTransfers.start_link([])
      Process.sleep(50)

      for l2_transaction_hash <- l2_transaction_hashes do
        :transaction
        |> insert(
          hash: l2_transaction_hash,
          from_address: get_address(fixture["l2_transaction_from"]),
          to_address: get_address(@l2_messenger),
          input: fixture["l2_transaction_input"]
        )
        |> with_block(insert(:block), status: :ok)
      end

      wait_for_completion()

      for l2_transaction_hash <- l2_transaction_hashes do
        assert stored_transfer(Repo.get!(Deposit, l2_transaction_hash)) == expected_transfer(fixture)
      end
    end

    test "a deposit whose L2 transaction never shows up is left undecoded once the retries run out" do
      l2_transaction_hash = insert_deposit_without_transaction()

      run_migration()

      assert Repo.get!(Deposit, l2_transaction_hash).transfer_type == nil
      assert MigrationStatus.get_status(@migration_name) == "completed"
    end

    test "keeps a transfer the indexer already decoded" do
      fixture = deposit(:eth)

      %{l2_transaction_hash: l2_transaction_hash} =
        insert_op_deposit_with_message(from: fixture["l2_transaction_from"], calldata: fixture["l2_transaction_input"])

      Repo.update_all(from(d in Deposit, where: d.l2_transaction_hash == ^l2_transaction_hash),
        set: [transfer_type: :message]
      )

      run_migration()

      assert Repo.get!(Deposit, l2_transaction_hash).transfer_type == :message
    end

    defp put_migration_env(settings) do
      Application.put_env(
        :explorer,
        OptimismDepositTransfers,
        Keyword.merge([batch_size: 2, concurrency: 1, retry_interval: 20], settings)
      )
    end

    defp run_migration do
      OptimismDepositTransfers.start_link([])
      wait_for_completion()
    end

    defp wait_for_completion(attempts \\ 500) do
      cond do
        MigrationStatus.get_status(@migration_name) == "completed" ->
          :ok

        attempts == 0 ->
          flunk("#{@migration_name} did not complete")

        true ->
          Process.sleep(10)
          wait_for_completion(attempts - 1)
      end
    end

    # The `op_deposit` factory always inserts the L2 transaction; `op_deposits` has no foreign key to `transactions`
    defp insert_deposit_without_transaction do
      l2_transaction_hash = transaction_hash()

      Repo.insert!(%Deposit{
        l1_block_number: 1,
        l1_block_timestamp: DateTime.utc_now(),
        l1_transaction_hash: transaction_hash(),
        l1_transaction_origin: address_hash(),
        l2_transaction_hash: l2_transaction_hash
      })

      l2_transaction_hash
    end

    defp get_address(hash_string) do
      {:ok, hash} = Hash.Address.cast(hash_string)
      Repo.get(Address, hash) || insert(:address, hash: hash)
    end
  end
end
