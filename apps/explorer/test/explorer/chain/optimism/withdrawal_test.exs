defmodule Explorer.Chain.Optimism.WithdrawalTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use Explorer.DataCase, async: false

    alias Explorer.Application.Constants
    alias Explorer.Chain.Cache.BackgroundMigrations
    alias Explorer.Chain.Optimism.{OutputRoot, Withdrawal, WithdrawalEvent}
    alias Explorer.{PagingOptions, QueryPlanHelper, Repo}
    alias Explorer.TestHelper

    defp insert_withdrawal(opts \\ []) do
      transaction = insert(:transaction, Keyword.take(opts, [:from_address]))

      Repo.insert!(%Withdrawal{
        msg_nonce: Decimal.new(opts[:msg_nonce] || System.unique_integer([:positive])),
        hash: Explorer.Factory.transaction_hash(),
        l2_transaction_hash: transaction.hash,
        l2_block_number: opts[:l2_block_number] || transaction.block_number || 1,
        transfer_from_address_hash: opts[:transfer_from],
        transfer_to_address_hash: opts[:transfer_to],
        transfer_type: opts[:transfer_type],
        message_hash: opts[:message_hash]
      })
    end

    defp status_of(withdrawal) do
      [%{status: status, challenge_period_end: challenge_period_end}] = Withdrawal.with_statuses([withdrawal], [])
      {status, challenge_period_end}
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

      test "until the bridge transfer backfill completes, the recipient of a withdrawal does not see it" do
        recipient = address_hash()
        insert_withdrawal(transfer_to: recipient)

        assert Withdrawal.list(address_hash: recipient) == []
        assert Withdrawal.count(address_hash: recipient) == 0
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

    describe "after the bridge transfer backfill" do
      setup do
        BackgroundMigrations.set_optimism_withdrawal_transfers_finished(true)
        on_exit(fn -> BackgroundMigrations.set_optimism_withdrawal_transfers_finished(false) end)
      end

      test "an address sees the withdrawals it sent and the ones it received, each once" do
        sender = insert(:address)
        address = sender.hash

        sent = insert_withdrawal(msg_nonce: 30, transfer_from: address, transfer_to: address_hash())
        received = insert_withdrawal(msg_nonce: 20, transfer_from: address_hash(), transfer_to: address)
        to_self = insert_withdrawal(msg_nonce: 10, transfer_from: address, transfer_to: address)
        # sending the L2 transaction alone no longer matches
        insert_withdrawal(msg_nonce: 5, from_address: sender)

        assert Enum.map(Withdrawal.list(address_hash: address), & &1.msg_nonce) ==
                 Enum.map([sent, received, to_self], & &1.msg_nonce)

        assert Withdrawal.count(address_hash: address) == 3
      end

      test "pages through both sides in order without repeating a withdrawal" do
        address = address_hash()

        expected =
          for nonce <- 5..1//-1 do
            side = if rem(nonce, 2) == 0, do: :transfer_from, else: :transfer_to
            insert_withdrawal([{:msg_nonce, nonce}, {side, address}]).msg_nonce
          end

        assert all_pages(address, nil) == expected
      end

      test "an address page and its count read the two transfer address indexes" do
        insert_unrelated_withdrawals(1_000)
        address = address_hash()
        # the page key sits above the unrelated nonces, as a real address page does among older withdrawals
        withdrawal = insert_withdrawal(msg_nonce: 2_000, transfer_from: address)
        page_options = %PagingOptions{page_size: 50, key: {withdrawal.msg_nonce}}

        list_plan =
          QueryPlanHelper.plan("op_withdrawals", fn ->
            Withdrawal.list(address_hash: address, paging_options: page_options)
          end)

        count_plan = QueryPlanHelper.plan("op_withdrawals", fn -> Withdrawal.count(address_hash: address) end)

        # each side reads its own index range, starting at the page key
        for index <- ~w(op_withdrawals_transfer_from_index op_withdrawals_transfer_to_index) do
          assert list_plan =~ ~r/#{index}[^\n]*\n\s*Index Cond: [^\n]*msg_nonce < /
          assert count_plan =~ index
        end
      end

      defp all_pages(address, key) do
        page = Withdrawal.list(address_hash: address, paging_options: %PagingOptions{page_size: 2, key: key})
        nonces = Enum.map(page, & &1.msg_nonce)

        case page do
          [_, last] -> nonces ++ all_pages(address, {last.msg_nonce})
          _ -> nonces
        end
      end

      # Withdrawals of other addresses, so that the planner weighs the address indexes against a table that is not empty
      defp insert_unrelated_withdrawals(count) do
        now = DateTime.utc_now()

        rows =
          for nonce <- 1..count do
            %{
              msg_nonce: Decimal.new(nonce),
              hash: transaction_hash(),
              l2_transaction_hash: transaction_hash(),
              l2_block_number: nonce,
              transfer_from_address_hash: address_hash(),
              transfer_to_address_hash: address_hash(),
              inserted_at: now,
              updated_at: now
            }
          end

        Repo.insert_all(Withdrawal, rows)
      end
    end

    describe "with_statuses/2" do
      test "derives the challenge period end from the proving event's L1 time and the stored period (LD6)" do
        Constants.set_constant_value(OutputRoot.finalization_period_constant(), "3600")
        proven_at = DateTime.add(DateTime.utc_now(), -600, :second)
        withdrawal = insert_withdrawal()
        prove = insert_proven(withdrawal, proven_at)

        assert [%{status: "In challenge period", challenge_period_end: end_at, prove_transaction_hash: prove_hash}] =
                 Withdrawal.with_statuses([page_item(withdrawal)], [])

        assert DateTime.compare(end_at, DateTime.add(proven_at, 3600)) == :eq
        assert prove_hash == prove.l1_transaction_hash
      end

      test "a proven withdrawal past the stored period is Ready for relay" do
        Constants.set_constant_value(OutputRoot.finalization_period_constant(), "3600")
        withdrawal = insert_withdrawal()
        insert_proven(withdrawal, DateTime.add(DateTime.utc_now(), -7200, :second))

        assert [%{status: "Ready for relay", challenge_period_end: nil}] =
                 Withdrawal.with_statuses([page_item(withdrawal)], [])
      end

      test "while no period is stored a proven withdrawal stays In challenge period, without a guessed end" do
        withdrawal = insert_withdrawal()
        insert_proven(withdrawal, DateTime.add(DateTime.utc_now(), -30 * 86_400, :second))

        assert [%{status: "In challenge period", challenge_period_end: nil}] =
                 Withdrawal.with_statuses([page_item(withdrawal)], [])
      end

      test "the latest proving transaction is the one reported" do
        withdrawal = insert_withdrawal()
        insert_proven(withdrawal, DateTime.add(DateTime.utc_now(), -900, :second), 10)
        latest = insert_proven(withdrawal, DateTime.add(DateTime.utc_now(), -600, :second), 20)

        assert [%{prove_transaction_hash: prove_hash}] = Withdrawal.with_statuses([page_item(withdrawal)], [])
        assert prove_hash == latest.l1_transaction_hash
      end

      test "an unproven withdrawal is Ready to prove once an output root covers its block, else Waiting for state root" do
        covered = insert_withdrawal(l2_block_number: 100)
        uncovered = insert_withdrawal(l2_block_number: 300)
        insert(:op_output_root, l2_block_number: 200)

        assert [%{status: "Ready to prove"}, %{status: "Waiting for state root"}] =
                 Withdrawal.with_statuses([page_item(covered), page_item(uncovered)], [])
      end

      test "reads a page of any size with the same number of queries" do
        Constants.set_constant_value(OutputRoot.finalization_period_constant(), "3600")
        insert(:op_output_root, l2_block_number: 1_000_000)

        withdrawals =
          for _ <- 1..5 do
            withdrawal = insert_withdrawal()
            insert_proven(withdrawal, DateTime.utc_now())
            page_item(withdrawal)
          end

        assert count_queries(fn -> Withdrawal.with_statuses(Enum.take(withdrawals, 1), []) end) ==
                 count_queries(fn -> Withdrawal.with_statuses(withdrawals, []) end)
      end

      defp page_item(withdrawal) do
        %{
          hash: withdrawal.hash,
          l2_block_number: withdrawal.l2_block_number,
          l1_transaction_hash: nil,
          relay_status: nil
        }
      end

      defp insert_proven(withdrawal, l1_timestamp, l1_block_number \\ 1) do
        Repo.insert!(%WithdrawalEvent{
          withdrawal_hash: withdrawal.hash,
          l1_event_type: :WithdrawalProven,
          l1_timestamp: l1_timestamp,
          l1_transaction_hash: transaction_hash(),
          l1_block_number: l1_block_number
        })
      end

      defp count_queries(fun) do
        handler_id = {:withdrawal_status_queries, make_ref()}
        test_process = self()

        :ok =
          :telemetry.attach(
            handler_id,
            [:explorer, :repo, :query],
            fn _event, _measurements, _metadata, _config ->
              if self() == test_process, do: send(test_process, {handler_id, :query})
            end,
            nil
          )

        try do
          fun.()
        after
          :telemetry.detach(handler_id)
        end

        count_messages(handler_id, 0)
      end

      defp count_messages(handler_id, count) do
        receive do
          {^handler_id, :query} -> count_messages(handler_id, count + 1)
        after
          0 -> count
        end
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
        assert status_of(withdrawal) == {"Relay failed", nil}
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
        assert status_of(withdrawal) == {"Relayed", nil}
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
        assert status_of(withdrawal) == {"Relay failed", nil}
      end

      test "a finalized withdrawal without an indexed relay keeps the old Relayed status" do
        insert_op_withdrawal_with_message(calldata: op_relay_message_calldata(), finalized_in: transaction_hash())

        assert [withdrawal] = Withdrawal.list()
        assert to_string(withdrawal.message_hash) == op_relay_message_hash()
        assert {withdrawal.relay_status, withdrawal.relay_transaction_hash} == {nil, nil}
        assert status_of(withdrawal) == {"Relayed", nil}
      end

      # The withdrawal fetcher reads the L2 events from the node, so a withdrawal can be stored, with its bridge transfer
      # decoded, before the block fetcher indexes the MessagePassed log
      test "a decoded withdrawal takes its relay result from the stored message hash, without its MessagePassed log" do
        finalize = transaction_hash()
        message_hash = TestHelper.topic(op_relay_message_hash())
        withdrawal = insert_withdrawal(transfer_type: :message, message_hash: message_hash)

        Repo.insert!(%WithdrawalEvent{
          withdrawal_hash: withdrawal.hash,
          l1_event_type: :WithdrawalFinalized,
          l1_timestamp: DateTime.utc_now(),
          l1_transaction_hash: finalize,
          l1_block_number: 1
        })

        insert(:op_message_relay,
          message_hash: message_hash,
          event_type: :FailedRelayedMessage,
          transaction_hash: finalize,
          chain: :l1
        )

        assert [listed] = Withdrawal.list()
        assert listed.message_hash == message_hash
        assert status_of(listed) == {"Relay failed", nil}
        assert [{_nonce, "Relay failed", _withdrawal}] = Withdrawal.transaction_statuses(withdrawal.l2_transaction_hash)
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
        assert status_of(withdrawal) == {"Relayed", nil}
      end

      test "a look-alike MessagePassed log from another contract is ignored" do
        withdrawal =
          insert_op_withdrawal_with_message(
            calldata: op_relay_message_calldata(),
            # a fresh address: a fixed one can collide with an address the factories generate afterwards
            emitter: to_string(insert(:address).hash),
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
