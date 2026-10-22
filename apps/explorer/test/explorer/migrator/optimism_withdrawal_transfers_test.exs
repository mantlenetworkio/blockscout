defmodule Explorer.Migrator.OptimismWithdrawalTransfersTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use Explorer.DataCase, async: false

    import Explorer.OptimismBridgeFixtures

    alias Explorer.Chain.Cache.BackgroundMigrations
    alias Explorer.Chain.{Data, Log, Transaction}
    alias Explorer.Chain.Optimism.Withdrawal
    alias Explorer.Migrator.{MigrationStatus, OptimismBridgeTransfers, OptimismWithdrawalTransfers}

    @migration_name "optimism_withdrawal_transfers"

    setup do
      configure_bridges()
      previous = Application.get_env(:explorer, OptimismWithdrawalTransfers)
      put_migration_env(retries: 3)

      on_exit(fn ->
        Application.put_env(:explorer, OptimismWithdrawalTransfers, previous)
        BackgroundMigrations.set_optimism_withdrawal_transfers_finished(false)
      end)
    end

    test "decodes the withdrawals indexed before B1 from their MessagePassed logs" do
      withdrawals =
        for name <- [:eth, :mnt, :erc20, :message] do
          {name, insert_op_withdrawal_with_message(message_passed: withdrawal(name)["message_passed"])}
        end

      run_migration()

      for {name, row} <- withdrawals do
        assert stored_transfer(Repo.get!(Withdrawal, row.msg_nonce)) == expected_transfer(withdrawal(name))
      end

      assert MigrationStatus.get_status(@migration_name) == "completed"
      assert BackgroundMigrations.get_optimism_withdrawal_transfers_finished()
    end

    test "two withdrawals of one transaction each get their own transfer (LD1)" do
      eth = insert_op_withdrawal_with_message(message_passed: withdrawal(:eth)["message_passed"])
      transaction = Repo.get!(Transaction, eth.l2_transaction_hash)

      erc20 =
        insert_op_withdrawal_with_message(
          message_passed: withdrawal(:erc20)["message_passed"],
          transaction: transaction
        )

      run_migration()

      assert stored_transfer(Repo.get!(Withdrawal, eth.msg_nonce)) == expected_transfer(withdrawal(:eth))
      assert stored_transfer(Repo.get!(Withdrawal, erc20.msg_nonce)) == expected_transfer(withdrawal(:erc20))
    end

    test "a withdrawal without its MessagePassed log stays undecoded and the migration completes" do
      # a fresh address: a fixed one can collide with an address the factories generate afterwards
      %{msg_nonce: nonce} = insert_op_withdrawal_with_message(emitter: to_string(insert(:address).hash))

      run_migration()

      assert Repo.get!(Withdrawal, nonce).transfer_type == nil
      assert MigrationStatus.get_status(@migration_name) == "completed"
    end

    test "a withdrawal whose MessagePassed log is indexed while the migration waits is decoded" do
      put_migration_env(retries: 100)
      %{msg_nonce: nonce} = row = insert_op_withdrawal_with_message(message_passed: withdrawal(:eth)["message_passed"])
      move_logs(row, insert(:address).hash)

      OptimismWithdrawalTransfers.start_link([])
      Process.sleep(100)
      move_logs(row, "0x4200000000000000000000000000000000000016")

      wait_for_completion()

      assert stored_transfer(Repo.get!(Withdrawal, nonce)) == expected_transfer(withdrawal(:eth))
    end

    test "a log of another withdrawal under the same transaction and nonce is not taken (a reorged block)" do
      %{msg_nonce: nonce} = row = insert_op_withdrawal_with_message(message_passed: withdrawal(:eth)["message_passed"])
      {:ok, other_data} = Data.cast(withdrawal(:erc20)["message_passed"]["data"])
      Repo.update_all(from(l in Log, where: l.transaction_hash == ^row.l2_transaction_hash), set: [data: other_data])

      run_migration()

      assert Repo.get!(Withdrawal, nonce).transfer_type == nil
    end

    test "the backfill update needs the withdrawal hash it decoded" do
      %{msg_nonce: nonce, hash: hash} = insert_op_withdrawal_with_message()
      keys = [{"msg_nonce", "numeric"}, {"hash", "bytea"}]
      transfer = expected_transfer(withdrawal(:eth))

      OptimismBridgeTransfers.update([{[nonce, transaction_hash().bytes], transfer}], "op_withdrawals", keys)
      assert Repo.get!(Withdrawal, nonce).transfer_type == nil

      OptimismBridgeTransfers.update([{[nonce, hash.bytes], transfer}], "op_withdrawals", keys)
      assert stored_transfer(Repo.get!(Withdrawal, nonce)) == transfer
    end

    test "keeps a transfer the indexer already decoded" do
      %{msg_nonce: nonce} = insert_op_withdrawal_with_message(message_passed: withdrawal(:eth)["message_passed"])
      Repo.update_all(from(w in Withdrawal, where: w.msg_nonce == ^nonce), set: [transfer_type: :message])

      run_migration()

      assert Repo.get!(Withdrawal, nonce).transfer_type == :message
    end

    defp put_migration_env(settings) do
      Application.put_env(
        :explorer,
        OptimismWithdrawalTransfers,
        Keyword.merge([batch_size: 2, concurrency: 1, retry_interval: 20], settings)
      )
    end

    # Makes the withdrawal's MessagePassed log come from another contract, or from the message passer again
    defp move_logs(withdrawal, address_hash) do
      Repo.update_all(from(l in Log, where: l.transaction_hash == ^withdrawal.l2_transaction_hash),
        set: [address_hash: address_hash]
      )
    end

    defp run_migration do
      OptimismWithdrawalTransfers.start_link([])
      wait_for_completion()
    end

    defp wait_for_completion(attempts \\ 300) do
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
  end
end
