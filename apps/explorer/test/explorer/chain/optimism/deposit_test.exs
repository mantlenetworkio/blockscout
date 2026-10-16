defmodule Explorer.Chain.Optimism.DepositTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use Explorer.DataCase, async: false

    alias Explorer.Chain.Optimism.Deposit
    alias Explorer.{PagingOptions, QueryPlanHelper, TestHelper}

    describe "list/1" do
      test "returns all deposits when :address_hash is not provided" do
        insert_list(3, :op_deposit)

        result = Deposit.list()

        assert length(result) == 3
      end

      test "returns only deposits whose l1_transaction_origin matches :address_hash" do
        target_address = build(:address)
        target_hash = target_address.hash

        matching = insert(:op_deposit, l1_transaction_origin: target_hash)
        insert(:op_deposit)
        insert(:op_deposit)

        result = Deposit.list(address_hash: target_hash)

        assert [returned] = result
        assert returned.l2_transaction_hash == matching.l2_transaction_hash
        assert returned.l1_transaction_origin == target_hash
      end

      test "returns empty list when no deposits match :address_hash" do
        insert_list(2, :op_deposit)
        other_address = build(:address)

        assert [] == Deposit.list(address_hash: other_address.hash)
      end

      test "treats :address_hash nil the same as omitted" do
        insert_list(2, :op_deposit)

        result_with_nil = Deposit.list(address_hash: nil)
        result_without_opt = Deposit.list()

        assert length(result_with_nil) == length(result_without_opt)
      end

      test "pages stay within :address_hash when other addresses deposit in the same L1 block" do
        origin = address_hash()

        # transaction_hash/0 is a sequence, so the L2 hashes grow in insertion order
        oldest = insert(:op_deposit, l1_transaction_origin: origin, l1_block_number: 100)
        insert(:op_deposit, l1_transaction_origin: address_hash(), l1_block_number: 100)
        newest = insert(:op_deposit, l1_transaction_origin: origin, l1_block_number: 100)

        assert [%{l2_transaction_hash: first_page}] =
                 Deposit.list(address_hash: origin, paging_options: %PagingOptions{page_size: 1})

        assert first_page == newest.l2_transaction_hash

        second_page_options = %PagingOptions{page_size: 1, key: {100, first_page}}

        assert [%{l2_transaction_hash: second_page}] =
                 Deposit.list(address_hash: origin, paging_options: second_page_options)

        assert second_page == oldest.l2_transaction_hash
      end
    end

    describe "count/1" do
      test "returns total count when :address_hash is not provided" do
        insert_list(4, :op_deposit)

        assert Deposit.count() == 4
      end

      test "returns count filtered by :address_hash" do
        target_address = build(:address)
        target_hash = target_address.hash

        insert(:op_deposit, l1_transaction_origin: target_hash)
        insert(:op_deposit, l1_transaction_origin: target_hash)
        insert(:op_deposit)
        insert(:op_deposit)

        assert Deposit.count(address_hash: target_hash) == 2
      end

      test "returns 0 when no deposits match :address_hash" do
        insert_list(3, :op_deposit)
        other_address = build(:address)

        assert Deposit.count(address_hash: other_address.hash) == 0
      end
    end

    describe "query plans" do
      test "an address page and its count use the origin index" do
        insert_unrelated_deposits(1_000)
        origin = address_hash()
        deposit = insert(:op_deposit, l1_transaction_origin: origin)
        page_options = %PagingOptions{page_size: 50, key: {deposit.l1_block_number, deposit.l2_transaction_hash}}

        list_plan =
          QueryPlanHelper.plan("op_deposits", fn -> Deposit.list(address_hash: origin, paging_options: page_options) end)

        count_plan = QueryPlanHelper.plan("op_deposits", fn -> Deposit.count(address_hash: origin) end)

        # the page key is part of the index condition, so the scan starts right at it
        assert list_plan =~
                 ~r/op_deposits_l1_transaction_origin_index[^\n]*\n\s*Index Cond: [^\n]*ROW\(l1_block_number, l2_transaction_hash\) < ROW/

        assert count_plan =~ "op_deposits_l1_transaction_origin_index"
      end
    end

    describe "relay status" do
      test "a deposit relayed by the messenger carries its message and relay result" do
        deposit = insert_op_deposit_with_message(calldata: op_relay_message_calldata())
        replay = transaction_hash()

        insert(:op_message_relay,
          message_hash: TestHelper.topic(op_relay_message_hash()),
          event_type: :FailedRelayedMessage,
          transaction_hash: deposit.l2_transaction_hash,
          chain: :l2,
          block_number: 10
        )

        insert(:op_message_relay,
          message_hash: TestHelper.topic(op_relay_message_hash()),
          event_type: :RelayedMessage,
          transaction_hash: replay,
          chain: :l2,
          block_number: 15
        )

        assert [item] = Deposit.list()
        assert to_string(item.message_hash) == op_relay_message_hash()
        assert {item.relay_status, item.relay_transaction_hash} == {:relayed, replay}
        assert to_string(item.msg_data) == op_relay_message_calldata()
        assert to_string(item.msg_target_address_hash) == "0x4200000000000000000000000000000000000007"
      end

      test "a deposit not sent to the messenger has no message fields" do
        insert_op_deposit_with_message(
          calldata: op_relay_message_calldata(),
          to: "0x00000000000000000000000000000000000000bb"
        )

        assert [item] = Deposit.list()

        assert {item.message_hash, item.relay_status, item.msg_data, item.msg_target_address_hash} ==
                 {nil, nil, nil, nil}
      end

      test "a deposit without an indexed relay has no relay status yet" do
        insert_op_deposit_with_message(calldata: op_relay_message_calldata())

        assert [item] = Deposit.list()
        assert to_string(item.message_hash) == op_relay_message_hash()
        assert {item.relay_status, item.relay_transaction_hash} == {nil, nil}
      end

      test "looks the relays of a whole page up with one query" do
        for _ <- 1..3, do: insert_op_deposit_with_message(calldata: op_relay_message_calldata() <> "00")

        handler_id = "op-deposit-relay-queries-#{System.unique_integer([:positive])}"
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

        assert length(Deposit.list()) == 3
        assert_received :relay_query
        refute_received :relay_query
      end
    end

    # Deposits of other origins, so that the planner weighs the origin index against a table that is not empty
    defp insert_unrelated_deposits(count) do
      now = DateTime.utc_now()

      rows =
        for block_number <- 1..count do
          %{
            l1_block_number: block_number,
            l1_transaction_hash: transaction_hash(),
            l1_transaction_origin: address_hash(),
            l2_transaction_hash: transaction_hash(),
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(Deposit, rows)
    end
  end
end
