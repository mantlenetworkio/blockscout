defmodule Explorer.Chain.Optimism.WithdrawalTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use Explorer.DataCase, async: false

    alias Explorer.Chain.Optimism.Withdrawal
    alias Explorer.Repo
    alias Explorer.TestHelper

    defp insert_withdrawal(opts \\ []) do
      transaction = insert(:transaction, Keyword.take(opts, [:from_address]))

      Repo.insert!(%Withdrawal{
        msg_nonce: Decimal.new(System.unique_integer([:positive])),
        hash: Explorer.Factory.transaction_hash(),
        l2_transaction_hash: transaction.hash,
        l2_block_number: transaction.block_number || 1
      })
    end

    describe "list/1" do
      test "returns all withdrawals when :address_hash is not provided" do
        insert_withdrawal()
        insert_withdrawal()
        insert_withdrawal()

        result = Withdrawal.list()

        assert length(result) == 3
      end

      test "returns only withdrawals whose l2_transaction.from_address_hash matches :address_hash" do
        target_address = insert(:address)
        target_hash = target_address.hash

        matching = insert_withdrawal(from_address: target_address)
        insert_withdrawal()
        insert_withdrawal()

        result = Withdrawal.list(address_hash: target_hash)

        assert [returned] = result
        assert returned.msg_nonce == matching.msg_nonce
        assert returned.from == target_hash
      end

      test "returns empty list when no withdrawals match :address_hash" do
        insert_withdrawal()
        insert_withdrawal()
        other_address = insert(:address)

        assert [] == Withdrawal.list(address_hash: other_address.hash)
      end

      test "treats :address_hash nil the same as omitted" do
        insert_withdrawal()
        insert_withdrawal()

        result_with_nil = Withdrawal.list(address_hash: nil)
        result_without_opt = Withdrawal.list()

        assert length(result_with_nil) == length(result_without_opt)
      end
    end

    describe "count/1" do
      test "returns total count when :address_hash is not provided" do
        insert_withdrawal()
        insert_withdrawal()
        insert_withdrawal()
        insert_withdrawal()

        assert Withdrawal.count() == 4
      end

      test "returns count filtered by :address_hash" do
        target_address = insert(:address)
        target_hash = target_address.hash

        insert_withdrawal(from_address: target_address)
        insert_withdrawal(from_address: target_address)
        insert_withdrawal()
        insert_withdrawal()

        assert Withdrawal.count(address_hash: target_hash) == 2
      end

      test "returns 0 when no withdrawals match :address_hash" do
        insert_withdrawal()
        insert_withdrawal()
        insert_withdrawal()
        other_address = insert(:address)

        assert Withdrawal.count(address_hash: other_address.hash) == 0
      end
    end

    describe "relay status" do
      test "a finalize whose relay failed is Relay failed" do
        finalize = transaction_hash()
        insert_op_withdrawal_with_message(calldata: op_relay_message_calldata(), finalized_in: finalize)

        insert(:op_message_relay,
          message_hash: TestHelper.topic(op_relay_message_hash()),
          event_type: :FailedRelayedMessage,
          transaction_hash: finalize,
          chain: :l1
        )

        assert [withdrawal] = Withdrawal.list()
        assert to_string(withdrawal.message_hash) == op_relay_message_hash()
        assert {withdrawal.relay_status, withdrawal.relay_transaction_hash} == {:failed, nil}
        assert Withdrawal.status(withdrawal, []) == {"Relay failed", nil}
      end

      test "a failed relay replayed in another transaction is Relayed with the replay" do
        finalize = transaction_hash()
        replay = transaction_hash()
        insert_op_withdrawal_with_message(calldata: op_relay_message_calldata(), finalized_in: finalize)

        for {event_type, relay_transaction_hash, block_number} <- [
              {:FailedRelayedMessage, finalize, 10},
              {:RelayedMessage, replay, 20}
            ] do
          insert(:op_message_relay,
            message_hash: TestHelper.topic(op_relay_message_hash()),
            event_type: event_type,
            transaction_hash: relay_transaction_hash,
            chain: :l1,
            block_number: block_number
          )
        end

        assert [withdrawal] = Withdrawal.list()
        assert {withdrawal.relay_status, withdrawal.relay_transaction_hash} == {:relayed, replay}
        assert Withdrawal.status(withdrawal, []) == {"Relayed", nil}
      end

      test "a relay indexed before the WithdrawalFinalized event already decides the status" do
        insert_op_withdrawal_with_message(calldata: op_relay_message_calldata())

        insert(:op_message_relay,
          message_hash: TestHelper.topic(op_relay_message_hash()),
          event_type: :FailedRelayedMessage,
          chain: :l1
        )

        assert [withdrawal] = Withdrawal.list()
        assert withdrawal.l1_transaction_hash == nil
        assert Withdrawal.status(withdrawal, []) == {"Relay failed", nil}
      end

      test "a finalized withdrawal without an indexed relay keeps the old Relayed status" do
        insert_op_withdrawal_with_message(calldata: op_relay_message_calldata(), finalized_in: transaction_hash())

        assert [withdrawal] = Withdrawal.list()
        assert to_string(withdrawal.message_hash) == op_relay_message_hash()
        assert {withdrawal.relay_status, withdrawal.relay_transaction_hash} == {nil, nil}
        assert Withdrawal.status(withdrawal, []) == {"Relayed", nil}
      end

      test "a message not sent through the L2CrossDomainMessenger has no message hash" do
        insert_op_withdrawal_with_message(
          calldata: op_relay_message_calldata(),
          sender: "0x00000000000000000000000000000000000000aa",
          finalized_in: transaction_hash()
        )

        insert(:op_message_relay,
          message_hash: TestHelper.topic(op_relay_message_hash()),
          event_type: :FailedRelayedMessage,
          chain: :l1
        )

        assert [withdrawal] = Withdrawal.list()
        assert {withdrawal.message_hash, withdrawal.relay_status} == {nil, nil}
        assert Withdrawal.status(withdrawal, []) == {"Relayed", nil}
      end

      test "a look-alike MessagePassed log from another contract is ignored" do
        withdrawal =
          insert_op_withdrawal_with_message(
            calldata: op_relay_message_calldata(),
            emitter: "0x00000000000000000000000000000000000000cc",
            finalized_in: transaction_hash()
          )

        insert(:op_message_relay,
          message_hash: TestHelper.topic(op_relay_message_hash()),
          event_type: :FailedRelayedMessage,
          chain: :l1
        )

        assert [item] = Withdrawal.list()
        assert {item.msg_log_data, item.message_hash, item.relay_status} == {nil, nil, nil}
        assert [{_nonce, "Relayed", _withdrawal}] = Withdrawal.transaction_statuses(withdrawal.l2_transaction_hash)
      end

      test "the Mantle MessagePassed layout hashes the same data" do
        initial_env = Application.get_all_env(:indexer)[Indexer.Fetcher.Optimism]
        Application.put_env(:indexer, Indexer.Fetcher.Optimism, Keyword.put(initial_env, :mantle_mode, true))
        on_exit(fn -> Application.put_env(:indexer, Indexer.Fetcher.Optimism, initial_env) end)

        insert_op_withdrawal_with_message(calldata: op_relay_message_calldata())

        assert [withdrawal] = Withdrawal.list()
        assert to_string(withdrawal.message_hash) == op_relay_message_hash()
      end

      test "the transaction page sees the relay result" do
        finalize = transaction_hash()

        withdrawal =
          insert_op_withdrawal_with_message(calldata: op_relay_message_calldata(), finalized_in: finalize)

        insert(:op_message_relay,
          message_hash: TestHelper.topic(op_relay_message_hash()),
          event_type: :FailedRelayedMessage,
          transaction_hash: finalize,
          chain: :l1
        )

        assert [{_nonce, "Relay failed", _withdrawal}] = Withdrawal.transaction_statuses(withdrawal.l2_transaction_hash)
      end

      test "looks the relays of a whole page up with one query" do
        for _ <- 1..3, do: insert_op_withdrawal_with_message(calldata: op_relay_message_calldata() <> "00")

        handler_id = "op-message-relay-queries-#{System.unique_integer([:positive])}"
        test_pid = self()

        :ok =
          :telemetry.attach(
            handler_id,
            [:explorer, :repo, :query],
            fn _event, _measurements, metadata, _config ->
              if String.contains?(metadata.query, ~s("op_message_relays")), do: send(test_pid, :relay_query)
            end,
            nil
          )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        assert length(Withdrawal.list()) == 3
        assert_received :relay_query
        refute_received :relay_query
      end
    end
  end
end
