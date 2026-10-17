defmodule Explorer.Chain.Optimism.BridgeHistoryTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use Explorer.DataCase, async: false

    import Explorer.OptimismBridgeFixtures
    import Explorer.OptimismLegacyBridgeFixtures

    alias Explorer.Application.Constants
    alias Explorer.Chain.Data

    alias Explorer.Chain.Optimism.{
      BridgeHistory,
      Deposit,
      LegacyBridgeTransfer,
      OutputRoot,
      Withdrawal,
      WithdrawalEvent
    }

    alias Explorer.{QueryPlanHelper, TestHelper}

    @l2_messenger "0x4200000000000000000000000000000000000007"
    @transfer_fields ~w(transfer_type transfer_from_address_hash transfer_to_address_hash l1_token_address_hash
                        l2_token_address_hash transfer_amount)a

    describe "deposits/2" do
      test "a deposit whose L2 transaction is not indexed is Pending, a reverted one Failed" do
        address = address_hash()
        pending = insert_bridge_deposit(from: address, l2_status: nil, l1_block_number: 20)
        failed = insert_bridge_deposit(from: address, l2_status: :error, l1_block_number: 10)

        assert [%{status: "Pending"} = first, %{status: "Failed"} = second] = BridgeHistory.deposits(address, limit: 10)

        assert {first.l2_transaction_hash, second.l2_transaction_hash} ==
                 {pending.l2_transaction_hash, failed.l2_transaction_hash}
      end

      test "a deposit that is not a messenger message is Relayed once its L2 transaction succeeded (LD7)" do
        address = address_hash()
        insert_bridge_deposit(from: address, message_hash: nil)

        assert [%{status: "Relayed", relay_transaction_hash: nil, msg_data: nil}] =
                 BridgeHistory.deposits(address, limit: 10)
      end

      test "a messenger deposit takes the L2 messenger's result; only a failed relay carries the replay payload (LD5)" do
        address = address_hash()
        relayed = insert_bridge_deposit(from: address, message_hash: transaction_hash(), l1_block_number: 30)

        failed =
          insert_bridge_deposit(
            from: address,
            message_hash: transaction_hash(),
            input: "0xff8daf15aa",
            l1_block_number: 20
          )

        unknown = insert_bridge_deposit(from: address, message_hash: transaction_hash(), l1_block_number: 10)
        relay = insert_relay(relayed.message_hash, :RelayedMessage, :l2)
        insert_relay(failed.message_hash, :FailedRelayedMessage, :l2)

        assert [relayed_item, failed_item, unknown_item] = BridgeHistory.deposits(address, limit: 10)

        assert %{status: "Relayed", msg_data: nil, msg_target_address_hash: nil} = relayed_item
        assert relayed_item.relay_transaction_hash == relay.transaction_hash

        assert %{status: "Relay failed", relay_transaction_hash: nil, msg_target_address_hash: @l2_messenger} =
                 failed_item

        assert to_string(failed_item.msg_data) == "0xff8daf15aa"
        # the L2 transaction ran, but its relay event is not indexed yet
        assert %{status: "Pending"} = unknown_item
        assert unknown.l2_transaction_hash == unknown_item.l2_transaction_hash
      end

      test "a failed relay replayed in another transaction is Relayed with the replay (LD3)" do
        address = address_hash()
        deposit = insert_bridge_deposit(from: address, message_hash: transaction_hash())
        insert_relay(deposit.message_hash, :FailedRelayedMessage, :l2, 10)
        replay = insert_relay(deposit.message_hash, :RelayedMessage, :l2, 20)

        assert [%{status: "Relayed", msg_data: nil} = item] = BridgeHistory.deposits(address, limit: 10)
        assert item.relay_transaction_hash == replay.transaction_hash
      end

      test "the recipient sees a deposit it did not send, and a deposit to oneself appears once" do
        address = address_hash()
        received = insert_bridge_deposit(to: address, l1_block_number: 20)
        to_self = insert_bridge_deposit(from: address, to: address, l1_block_number: 10)

        assert Enum.map(BridgeHistory.deposits(address, limit: 10), & &1.l2_transaction_hash) ==
                 [received.l2_transaction_hash, to_self.l2_transaction_hash]
      end

      test "the deposits of one L1 transaction appear one by one, and its hash finds them all (LD1)" do
        sender = address_hash()
        l1_transaction_hash = transaction_hash()
        first = insert_bridge_deposit(from: sender, to: address_hash(), l1_transaction_hash: l1_transaction_hash)
        second = insert_bridge_deposit(from: sender, to: address_hash(), l1_transaction_hash: l1_transaction_hash)
        insert_bridge_deposit(from: sender)

        assert [%{l2_transaction_hash: only}] = BridgeHistory.deposits(first.transfer_to_address_hash, limit: 10)
        assert only == first.l2_transaction_hash

        assert sender
               |> BridgeHistory.deposits(limit: 10, transaction_hash: l1_transaction_hash)
               |> Enum.map(& &1.l2_transaction_hash)
               |> Enum.sort() ==
                 Enum.sort([first.l2_transaction_hash, second.l2_transaction_hash])
      end

      test "pages walk both sides in order without repeating a deposit" do
        address = address_hash()

        expected =
          for block_number <- 5..1//-1 do
            side = if rem(block_number, 2) == 0, do: :from, else: :to
            insert_bridge_deposit([{side, address}, {:l1_block_number, block_number}]).l1_transaction_hash
          end

        assert deposit_pages(address, nil, 2) == expected
      end

      test "keeps the transfer amount exact (LD9)" do
        address = address_hash()
        insert_bridge_deposit(from: address, amount: Decimal.new("123456789012345678901234567890"))

        assert [%{transfer_amount: amount}] = BridgeHistory.deposits(address, limit: 10)
        assert Decimal.equal?(amount, Decimal.new("123456789012345678901234567890"))
      end

      test "a page of any size costs the same number of queries" do
        address = address_hash()
        one = insert_bridge_deposit(from: address, message_hash: transaction_hash(), l1_block_number: 100)
        insert_relay(one.message_hash, :FailedRelayedMessage, :l2)

        single = count_queries(fn -> BridgeHistory.deposits(address, limit: 10) end)

        for block_number <- 1..4 do
          deposit =
            insert_bridge_deposit(from: address, message_hash: transaction_hash(), l1_block_number: block_number)

          insert_relay(deposit.message_hash, :FailedRelayedMessage, :l2)
        end

        assert count_queries(fn -> BridgeHistory.deposits(address, limit: 10) end) == single
      end

      test "an address page reads one bounded index range per side, a transaction page its own index" do
        insert_unrelated_deposits(1_000)
        address = address_hash()
        deposit = insert_bridge_deposit(from: address)

        page_plan = QueryPlanHelper.plan("op_deposits", fn -> BridgeHistory.deposits(address, limit: 51) end)

        transaction_plan =
          QueryPlanHelper.plan("op_deposits", fn ->
            BridgeHistory.deposits(address, limit: 51, transaction_hash: deposit.l1_transaction_hash)
          end)

        next_page_plan =
          QueryPlanHelper.plan("op_deposits", fn ->
            BridgeHistory.deposits(address,
              limit: 51,
              paging_key: {deposit.l1_block_number, deposit.l2_transaction_hash}
            )
          end)

        for index <- ~w(op_deposits_transfer_from_index op_deposits_transfer_to_index) do
          assert page_plan =~ ~r/Limit[^\n]*\n\s*->\s+Index Scan Backward using #{index}/

          # a later page starts its index ranges right at the page key
          assert next_page_plan =~
                   ~r/#{index}[^\n]*\n\s*Index Cond: [^\n]*ROW\(l1_block_number, l2_transaction_hash\) < ROW/
        end

        assert transaction_plan =~ "op_deposits_l1_transaction_hash_index"
      end
    end

    describe "withdrawals/2" do
      setup do
        configure_bridges()
        :ok
      end

      test "reports the status, the proving and finalizing transactions and the L2 time" do
        Constants.set_constant_value(OutputRoot.finalization_period_constant(), "3600")
        address = address_hash()
        withdrawal = insert_bridge_withdrawal(:eth, from: address)
        proven_at = DateTime.add(DateTime.utc_now(), -600, :second)
        prove = insert_withdrawal_event(withdrawal, :WithdrawalProven, proven_at)

        assert [item] = BridgeHistory.withdrawals(address, limit: 10)
        assert %{status: "In challenge period", l1_transaction_hash: nil, msg_data: nil} = item
        assert item.prove_transaction_hash == prove.l1_transaction_hash
        assert DateTime.compare(item.challenge_period_end, DateTime.add(proven_at, 3600)) == :eq
        assert item.l2_timestamp != nil
      end

      test "two withdrawals finalized in one L1 transaction both report it (LD4)" do
        address = address_hash()
        finalize = transaction_hash()
        first = insert_bridge_withdrawal(:eth, from: address)
        second = insert_bridge_withdrawal(:erc20, from: address)
        insert_withdrawal_event(first, :WithdrawalFinalized, DateTime.utc_now(), finalize)
        insert_withdrawal_event(second, :WithdrawalFinalized, DateTime.utc_now(), finalize)

        assert [%{l1_transaction_hash: a, status: "Relayed"}, %{l1_transaction_hash: b, status: "Relayed"}] =
                 BridgeHistory.withdrawals(address, limit: 10)

        assert {a, b} == {finalize, finalize}
      end

      test "only a failed relay carries the replay payload, from the withdrawal's own MessagePassed log (LD5)" do
        address = address_hash()
        failed = insert_bridge_withdrawal(:eth, from: address)
        relayed = insert_bridge_withdrawal(:erc20, from: address)
        insert_relay(failed.message_hash, :FailedRelayedMessage, :l1)
        insert_relay(relayed.message_hash, :RelayedMessage, :l1)

        items = BridgeHistory.withdrawals(address, limit: 10)
        failed_item = Enum.find(items, &(&1.msg_nonce == failed.msg_nonce))
        relayed_item = Enum.find(items, &(&1.msg_nonce == relayed.msg_nonce))
        message = Withdrawal.parse_message_passed_data(withdrawal(:eth)["message_passed"]["data"], true)

        assert %{status: "Relay failed", msg_target_address_hash: "0x37dac5312e31adb8bb0802fc72ca84da5cdfcb4c"} =
                 failed_item

        assert failed_item.msg_data == %Data{bytes: message.data}
        assert failed_item.msg_gas_limit == message.gas_limit
        assert %{status: "Relayed", msg_data: nil, msg_gas_limit: nil} = relayed_item
      end

      test "of two finalizations left by a reorged L1 block, the latest is reported" do
        address = address_hash()
        withdrawal = insert_bridge_withdrawal(:eth, from: address)
        # the older event comes first both by transaction hash and in the table
        {:ok, older} = Explorer.Chain.Hash.Full.cast("0x" <> String.duplicate("00", 31) <> "01")
        {:ok, newer} = Explorer.Chain.Hash.Full.cast("0x" <> String.duplicate("ff", 32))
        insert_withdrawal_event(withdrawal, :WithdrawalFinalized, DateTime.utc_now(), older, 10)
        insert_withdrawal_event(withdrawal, :WithdrawalFinalized, DateTime.utc_now(), newer, 20)

        assert [%{l1_transaction_hash: l1_transaction_hash}] = BridgeHistory.withdrawals(address, limit: 10)
        assert l1_transaction_hash == newer
      end

      test "a failed relay replayed in another transaction is Relayed with the replay (LD3)" do
        address = address_hash()
        withdrawal = insert_bridge_withdrawal(:eth, from: address)
        insert_relay(withdrawal.message_hash, :FailedRelayedMessage, :l1, 10)
        replay = insert_relay(withdrawal.message_hash, :RelayedMessage, :l1, 20)

        assert [%{status: "Relayed", msg_data: nil} = item] = BridgeHistory.withdrawals(address, limit: 10)
        assert item.relay_transaction_hash == replay.transaction_hash
      end

      test "the recipient sees it, its L2 transaction finds it, and pages walk both sides by nonce" do
        address = address_hash()
        received = insert_bridge_withdrawal(:eth, to: address)
        sent = insert_bridge_withdrawal(:mnt, from: address)
        to_self = insert_bridge_withdrawal(:erc20, from: address, to: address)

        assert withdrawal_pages(address, nil) ==
                 [received, sent, to_self] |> Enum.map(& &1.msg_nonce) |> Enum.sort(&Decimal.gt?/2)

        assert [%{msg_nonce: nonce}] =
                 BridgeHistory.withdrawals(address, limit: 10, transaction_hash: sent.l2_transaction_hash)

        assert nonce == sent.msg_nonce
      end

      test "a page of any size costs the same number of queries" do
        Constants.set_constant_value(OutputRoot.finalization_period_constant(), "3600")
        address = address_hash()
        one = insert_bridge_withdrawal(:eth, from: address)
        insert_relay(one.message_hash, :FailedRelayedMessage, :l1)
        insert_withdrawal_event(one, :WithdrawalProven, DateTime.utc_now())

        single = count_queries(fn -> BridgeHistory.withdrawals(address, limit: 10) end)

        for name <- [:mnt, :erc20, :message] do
          withdrawal = insert_bridge_withdrawal(name, from: address)
          insert_relay(withdrawal.message_hash, :FailedRelayedMessage, :l1)
          insert_withdrawal_event(withdrawal, :WithdrawalProven, DateTime.utc_now())
        end

        assert count_queries(fn -> BridgeHistory.withdrawals(address, limit: 10) end) == single
      end

      test "an address page reads one bounded index range per side, a transaction page its own index" do
        insert_unrelated_withdrawals(1_000)
        address = address_hash()
        withdrawal = insert_bridge_withdrawal(:eth, from: address)

        page_plan = QueryPlanHelper.plan("op_withdrawals", fn -> BridgeHistory.withdrawals(address, limit: 51) end)

        transaction_plan =
          QueryPlanHelper.plan("op_withdrawals", fn ->
            BridgeHistory.withdrawals(address, limit: 51, transaction_hash: withdrawal.l2_transaction_hash)
          end)

        for index <- ~w(op_withdrawals_transfer_from_index op_withdrawals_transfer_to_index) do
          assert page_plan =~ ~r/Limit[^\n]*\n\s*->\s+Index Scan Backward using #{index}/
        end

        assert transaction_plan =~ "op_withdrawals_l2_transaction_hash_index"
      end
    end

    describe "v1 history" do
      setup do
        configure_legacy_bridges("sepolia")
        :ok
      end

      test "is served only once the backfill is validated" do
        address = address_hash()
        insert_legacy(:deposit, :eth, %{transfer_from_address_hash: address})
        insert_legacy(:withdrawal, :mnt, %{transfer_to_address_hash: address})

        assert BridgeHistory.deposits(address, limit: 10) == []
        assert BridgeHistory.withdrawals(address, limit: 10) == []

        Constants.set_constant_value(LegacyBridgeTransfer.validated_constant(), "false")
        assert BridgeHistory.deposits(address, limit: 10) == []
        assert BridgeHistory.withdrawals(address, limit: 10) == []

        validate_legacy()
        assert [%{is_legacy: true}] = BridgeHistory.deposits(address, limit: 10)
        assert [%{is_legacy: true}] = BridgeHistory.withdrawals(address, limit: 10)
      end

      test "a v1 deposit takes its status from the L2 relay of its v0 hash" do
        validate_legacy()
        address = address_hash()
        relayed = insert_legacy(:deposit, :eth, %{transfer_from_address_hash: address})
        failed = insert_legacy(:deposit, :mnt, %{transfer_from_address_hash: address})
        pending = insert_legacy(:deposit, :erc20, %{transfer_to_address_hash: address})
        relay = insert_relay(relayed.message_hash, :RelayedMessage, :l2)
        insert_relay(failed.message_hash, :FailedRelayedMessage, :l2)

        items = Map.new(BridgeHistory.deposits(address, limit: 10), &{&1.message_hash, &1})

        assert %{status: "Relayed", is_legacy: true, transfer_type: :eth, msg_data: nil} =
                 relayed_item = items[relayed.message_hash]

        # the L2 transaction of a v1 deposit is the one that relayed it
        assert relayed_item.l2_transaction_hash == relay.transaction_hash
        assert relayed_item.relay_transaction_hash == relay.transaction_hash

        assert {relayed_item.l1_transaction_hash, relayed_item.l1_block_number, relayed_item.l1_block_timestamp} ==
                 {relayed.transaction_hash, relayed.block_number, relayed.timestamp}

        # the v1 columns line up with the v2 ones, from and to included
        pending_item = items[pending.message_hash]

        assert Map.take(pending_item, @transfer_fields) == Map.take(pending, @transfer_fields)
        assert pending_item.l1_token_address_hash != nil
        assert {pending_item.mnt_value, pending_item.eth_value} == {nil, nil}

        # the v2 messenger cannot replay a v0 message, so there is no replay payload
        assert %{status: "Relay failed", l2_transaction_hash: nil, msg_data: nil, msg_target_address_hash: nil} =
                 items[failed.message_hash]

        assert %{status: "Pending", l2_transaction_hash: nil, relay_transaction_hash: nil} = items[pending.message_hash]
      end

      test "a v1 withdrawal relayed in the v1 era is Relayed; an open one follows the v2 portal as migrated" do
        validate_legacy()
        Constants.set_constant_value(OutputRoot.finalization_period_constant(), "3600")
        # every v2 output root covers the pre-Bedrock blocks
        insert(:op_output_root, l2_block_number: 1_000_000_000)
        address = address_hash()
        v1_relayed = insert_legacy(:withdrawal, :eth, %{transfer_from_address_hash: address})
        unproven = insert_legacy(:withdrawal, :mnt, %{transfer_from_address_hash: address})
        proven = insert_legacy(:withdrawal, :erc20, %{transfer_to_address_hash: address})
        relay_failed = insert_legacy(:withdrawal, :eth_mainnet, %{transfer_from_address_hash: address})

        v1_relay = insert_relay(v1_relayed.message_hash, :RelayedMessage, :l1)
        # the v2 messenger keeps no record of a v1-era failure: the withdrawal is proven and finalized anew
        insert_relay(unproven.message_hash, :FailedRelayedMessage, :l1)
        proven_at = DateTime.add(DateTime.utc_now(), -600, :second)
        prove = insert_withdrawal_event(%{hash: proven.migrated_withdrawal_hash}, :WithdrawalProven, proven_at)

        insert_withdrawal_event(
          %{hash: relay_failed.migrated_withdrawal_hash},
          :WithdrawalFinalized,
          DateTime.utc_now()
        )

        insert_relay(relay_failed.migrated_message_hash, :FailedRelayedMessage, :l1)

        items = BridgeHistory.withdrawals(address, limit: 10)

        assert %{status: "Relayed", is_legacy: true, msg_data: nil} = relayed_item = find_nonce(items, v1_relayed)
        # in the v1 era the L1 relay was the finalization
        assert relayed_item.relay_transaction_hash == v1_relay.transaction_hash
        assert relayed_item.l1_transaction_hash == v1_relay.transaction_hash

        assert {relayed_item.l2_transaction_hash, relayed_item.l2_block_number, relayed_item.l2_timestamp} ==
                 {v1_relayed.transaction_hash, v1_relayed.block_number, v1_relayed.timestamp}

        assert %{status: "Ready to prove", msg_data: nil, prove_transaction_hash: nil} = find_nonce(items, unproven)

        assert %{status: "In challenge period"} = proven_item = find_nonce(items, proven)
        assert proven_item.prove_transaction_hash == prove.l1_transaction_hash
        assert DateTime.compare(proven_item.challenge_period_end, DateTime.add(proven_at, 3600)) == :eq

        assert %{status: "Relay failed", msg_target_address_hash: "0x37dac5312e31adb8bb0802fc72ca84da5cdfcb4c"} =
                 failed_item = find_nonce(items, relay_failed)

        assert Map.take(find_nonce(items, proven), @transfer_fields) == Map.take(proven, @transfer_fields)
        assert find_nonce(items, proven).hash == proven.migrated_withdrawal_hash

        assert failed_item.message_hash == relay_failed.migrated_message_hash
        assert failed_item.msg_data == relay_failed.migrated_msg_data
        assert failed_item.msg_gas_limit == Decimal.to_integer(relay_failed.migrated_gas_limit)
      end

      test "pages run through the v2 items, then the v1 ones, each once; a transaction finds its v1 items" do
        validate_legacy()
        address = address_hash()

        v2_deposits =
          for block <- [9_000_001, 9_000_000], do: insert_bridge_deposit(from: address, l1_block_number: block)

        v1_mnt_deposit = insert_legacy(:deposit, :mnt, %{transfer_to_address_hash: address})
        v1_eth_deposit = insert_legacy(:deposit, :eth, %{transfer_from_address_hash: address})
        # a relayed v1 deposit shows the relay as its L2 transaction, but pages by its v0 hash
        insert_relay(v1_mnt_deposit.message_hash, :RelayedMessage, :l2)

        assert deposit_pages(address, nil, 1) ==
                 Enum.map(v2_deposits, & &1.l1_transaction_hash) ++
                   [v1_mnt_deposit.transaction_hash, v1_eth_deposit.transaction_hash]

        v2_withdrawals = [insert_bridge_withdrawal(:eth, from: address), insert_bridge_withdrawal(:mnt, to: address)]
        v1_eth_withdrawal = insert_legacy(:withdrawal, :eth, %{transfer_from_address_hash: address})
        v1_mnt_withdrawal = insert_legacy(:withdrawal, :mnt, %{transfer_to_address_hash: address})

        assert address |> withdrawal_pages(nil, 1) |> Enum.map(&Decimal.to_string/1) ==
                 ((v2_withdrawals |> Enum.map(& &1.msg_nonce) |> Enum.sort(&Decimal.gt?/2)) ++
                    [v1_eth_withdrawal.nonce, v1_mnt_withdrawal.nonce])
                 |> Enum.map(&Decimal.to_string/1)

        assert [%{is_legacy: true, l1_transaction_hash: l1_transaction_hash}] =
                 BridgeHistory.deposits(address, limit: 10, transaction_hash: v1_eth_deposit.transaction_hash)

        assert l1_transaction_hash == v1_eth_deposit.transaction_hash

        assert [%{is_legacy: true} = withdrawal] =
                 BridgeHistory.withdrawals(address, limit: 10, transaction_hash: v1_mnt_withdrawal.transaction_hash)

        assert Decimal.equal?(withdrawal.msg_nonce, v1_mnt_withdrawal.nonce)
      end

      test "a page with v1 items costs as many queries as one without" do
        validate_legacy()
        Constants.set_constant_value(OutputRoot.finalization_period_constant(), "3600")
        address = address_hash()

        v2_deposit = insert_bridge_deposit(from: address, message_hash: transaction_hash(), l1_block_number: 9_000_000)
        insert_relay(v2_deposit.message_hash, :FailedRelayedMessage, :l2)
        v2_withdrawal = insert_bridge_withdrawal(:eth, from: address)
        insert_relay(v2_withdrawal.message_hash, :FailedRelayedMessage, :l1)
        insert_withdrawal_event(v2_withdrawal, :WithdrawalProven, DateTime.utc_now())

        deposit_queries = count_queries(fn -> BridgeHistory.deposits(address, limit: 10) end)
        withdrawal_queries = count_queries(fn -> BridgeHistory.withdrawals(address, limit: 10) end)

        for {name, event_type} <- [eth: :RelayedMessage, mnt: :FailedRelayedMessage, erc20: nil] do
          deposit = insert_legacy(:deposit, name, %{transfer_from_address_hash: address})
          withdrawal = insert_legacy(:withdrawal, name, %{transfer_from_address_hash: address})
          insert_withdrawal_event(%{hash: withdrawal.migrated_withdrawal_hash}, :WithdrawalProven, DateTime.utc_now())

          if event_type do
            insert_relay(deposit.message_hash, event_type, :l2)
            insert_relay(withdrawal.migrated_message_hash, event_type, :l1)
          end
        end

        # the pages now hold the v1 items too
        assert length(BridgeHistory.deposits(address, limit: 10)) == 4
        assert length(BridgeHistory.withdrawals(address, limit: 10)) == 4

        assert count_queries(fn -> BridgeHistory.deposits(address, limit: 10) end) == deposit_queries
        assert count_queries(fn -> BridgeHistory.withdrawals(address, limit: 10) end) == withdrawal_queries
      end

      test "a page reads the v1 rows through their partial indexes, one bounded range per side" do
        validate_legacy()
        insert_unrelated_legacy(1_000)
        address = address_hash()
        deposit = insert_legacy(:deposit, :eth, %{transfer_from_address_hash: address})
        withdrawal = insert_legacy(:withdrawal, :eth, %{transfer_from_address_hash: address})
        table = "mantle_legacy_bridge_transfers"

        deposit_plan = QueryPlanHelper.plan(table, fn -> BridgeHistory.deposits(address, limit: 51) end)
        withdrawal_plan = QueryPlanHelper.plan(table, fn -> BridgeHistory.withdrawals(address, limit: 51) end)

        next_deposit_plan =
          QueryPlanHelper.plan(table, fn ->
            BridgeHistory.deposits(address, limit: 51, paging_key: {deposit.block_number, deposit.message_hash})
          end)

        next_withdrawal_plan =
          QueryPlanHelper.plan(table, fn ->
            BridgeHistory.withdrawals(address, limit: 51, paging_key: withdrawal.nonce)
          end)

        for side <- ~w(from to) do
          deposit_index = "mantle_legacy_bridge_deposits_#{side}_index"
          withdrawal_index = "mantle_legacy_bridge_withdrawals_#{side}_index"

          assert deposit_plan =~ ~r/Limit[^\n]*\n\s*->\s+Index Scan Backward using #{deposit_index}/
          assert withdrawal_plan =~ ~r/Limit[^\n]*\n\s*->\s+Index Scan Backward using #{withdrawal_index}/

          # a later page starts its index ranges right at the page key
          assert next_deposit_plan =~
                   ~r/#{deposit_index}[^\n]*\n\s*Index Cond: [^\n]*ROW\(block_number, message_hash\) < ROW/

          assert next_withdrawal_plan =~ ~r/#{withdrawal_index}[^\n]*\n\s*Index Cond: [^\n]*nonce < /
        end

        transaction_plan =
          QueryPlanHelper.plan(table, fn ->
            BridgeHistory.deposits(address, limit: 51, transaction_hash: deposit.transaction_hash)
          end)

        assert transaction_plan =~ "mantle_legacy_bridge_transfers_transaction_hash_index"
      end
    end

    defp validate_legacy, do: Constants.set_constant_value(LegacyBridgeTransfer.validated_constant(), "true")

    defp find_nonce(items, %LegacyBridgeTransfer{nonce: nonce}),
      do: Enum.find(items, &Decimal.equal?(&1.msg_nonce, nonce))

    # A deposit with its bridge transfer. `l2_status: nil` leaves its L2 transaction unindexed.
    defp insert_bridge_deposit(opts) do
      l2_transaction_hash =
        case Keyword.get(opts, :l2_status, :ok) do
          nil ->
            transaction_hash()

          status ->
            :transaction
            |> insert(input: Keyword.get(opts, :input, "0x"))
            |> with_block(insert(:block), status: status, error: if(status == :error, do: "Reverted"))
            |> Map.fetch!(:hash)
        end

      Repo.insert!(%Deposit{
        l1_block_number: Keyword.get_lazy(opts, :l1_block_number, fn -> System.unique_integer([:positive]) end),
        l1_block_timestamp: DateTime.utc_now(),
        l1_transaction_hash: Keyword.get_lazy(opts, :l1_transaction_hash, &transaction_hash/0),
        l1_transaction_origin: address_hash(),
        l2_transaction_hash: l2_transaction_hash,
        message_hash: Keyword.get(opts, :message_hash),
        transfer_type: :eth,
        transfer_from_address_hash: Keyword.get_lazy(opts, :from, &address_hash/0),
        transfer_to_address_hash: Keyword.get_lazy(opts, :to, &address_hash/0),
        transfer_amount: Keyword.get(opts, :amount, Decimal.new(1)),
        mnt_value: Decimal.new(0),
        eth_value: Decimal.new(1)
      })
    end

    # A withdrawal with the MessagePassed log of a fixture, decoded as if by the indexer, with its sender and recipient
    # overridable
    defp insert_bridge_withdrawal(fixture_name, opts) do
      fixture = withdrawal(fixture_name)
      expected = expected_transfer(fixture)
      row = insert_op_withdrawal_with_message(message_passed: fixture["message_passed"])

      transfer = %{
        expected
        | transfer_from_address_hash: Keyword.get_lazy(opts, :from, &address_hash/0),
          transfer_to_address_hash: Keyword.get_lazy(opts, :to, &address_hash/0)
      }

      {1, [updated]} =
        Repo.update_all(
          from(w in Withdrawal, where: w.msg_nonce == ^row.msg_nonce, select: w),
          set: Enum.map(transfer, fn {key, value} -> {key, cast(key, value)} end)
        )

      updated
    end

    defp cast(:transfer_type, value), do: value
    defp cast(key, value) when key in [:transfer_amount, :mnt_value, :eth_value], do: value && Decimal.new(value)
    defp cast(:message_hash, value), do: value && TestHelper.topic(value)
    defp cast(_key, %Explorer.Chain.Hash{} = value), do: value

    defp cast(_key, value) when is_binary(value) do
      {:ok, hash} = Explorer.Chain.Hash.Address.cast(value)
      hash
    end

    defp cast(_key, nil), do: nil

    defp insert_relay(message_hash, event_type, chain, block_number \\ 10) do
      insert(:op_message_relay,
        message_hash: message_hash,
        event_type: event_type,
        transaction_hash: transaction_hash(),
        chain: chain,
        block_number: block_number
      )
    end

    defp insert_withdrawal_event(
           withdrawal,
           event_type,
           l1_timestamp,
           l1_transaction_hash \\ nil,
           l1_block_number \\ nil
         ) do
      Repo.insert!(%WithdrawalEvent{
        withdrawal_hash: withdrawal.hash,
        l1_event_type: event_type,
        l1_timestamp: l1_timestamp,
        l1_transaction_hash: l1_transaction_hash || transaction_hash(),
        l1_block_number: l1_block_number || System.unique_integer([:positive])
      })
    end

    # The L1 transaction hashes of all pages; a v2 deposit's own L2 transaction hash is checked by the callers above
    defp deposit_pages(address, paging_key, limit) do
      page = BridgeHistory.deposits(address, limit: limit, paging_key: paging_key)
      hashes = Enum.map(page, & &1.l1_transaction_hash)

      if length(page) == limit,
        do: hashes ++ deposit_pages(address, List.last(page).paging_key, limit),
        else: hashes
    end

    defp withdrawal_pages(address, paging_key, limit \\ 2) do
      page = BridgeHistory.withdrawals(address, limit: limit, paging_key: paging_key)
      nonces = Enum.map(page, & &1.msg_nonce)

      if length(page) == limit,
        do: nonces ++ withdrawal_pages(address, List.last(page).msg_nonce, limit),
        else: nonces
    end

    # Rows of other addresses, so that the planner weighs the indexes against tables that are not empty
    defp insert_unrelated_legacy(count) do
      now = DateTime.utc_now()

      Repo.insert_all(
        LegacyBridgeTransfer,
        for nonce <- 1..count, direction <- [:deposit, :withdrawal] do
          %{
            direction: direction,
            nonce: Decimal.new(nonce),
            transaction_hash: transaction_hash(),
            block_number: nonce,
            transfer_type: :eth,
            transfer_from_address_hash: address_hash(),
            transfer_to_address_hash: address_hash(),
            message_hash: transaction_hash(),
            migrated_withdrawal_hash: if(direction == :withdrawal, do: transaction_hash()),
            inserted_at: now,
            updated_at: now
          }
        end
      )
    end

    defp insert_unrelated_deposits(count) do
      now = DateTime.utc_now()

      Repo.insert_all(
        Deposit,
        for block_number <- 1..count do
          %{
            l1_block_number: block_number,
            l1_transaction_hash: transaction_hash(),
            l1_transaction_origin: address_hash(),
            l2_transaction_hash: transaction_hash(),
            transfer_type: :eth,
            transfer_from_address_hash: address_hash(),
            transfer_to_address_hash: address_hash(),
            inserted_at: now,
            updated_at: now
          }
        end
      )
    end

    defp insert_unrelated_withdrawals(count) do
      now = DateTime.utc_now()

      Repo.insert_all(
        Withdrawal,
        for nonce <- 1..count do
          %{
            msg_nonce: Decimal.new(nonce),
            hash: transaction_hash(),
            l2_transaction_hash: transaction_hash(),
            l2_block_number: nonce,
            transfer_type: :eth,
            transfer_from_address_hash: address_hash(),
            transfer_to_address_hash: address_hash(),
            inserted_at: now,
            updated_at: now
          }
        end
      )
    end

    defp count_queries(fun) do
      handler_id = {:bridge_history_queries, make_ref()}
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
end
