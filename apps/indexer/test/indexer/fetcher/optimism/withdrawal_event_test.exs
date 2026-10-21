if Application.get_env(:explorer, :chain_type) == :optimism do
  defmodule Indexer.Fetcher.Optimism.WithdrawalEventTest do
    use EthereumJSONRPC.Case, async: false
    use Explorer.DataCase

    import Mox

    alias Explorer.Chain.Cache.LatestL1BlockNumber
    alias Explorer.Chain.Optimism.MessageRelay
    alias Explorer.Chain.Optimism.WithdrawalEvent, as: WithdrawalEventSchema
    alias Explorer.Repo
    alias Indexer.Fetcher.Optimism.{MessageRelayL1, WithdrawalEvent}
    alias Indexer.RollupReorgMonitorQueue

    @portal "0xc54cb22944f2be476e02decfcd7e3e7d3e15a8fb"
    @messenger "0x37dac5312e31adb8bb0802fc72ca84da5cdfcb4c"
    @proven "0x67a6208cfcc0801d50f6cbe764733f4fddf66ac0b04442061a8a8c0cb6b63f62"
    @proven_blast "0x5d5446905f1f582d57d04ced5b1bed0f1a6847bcee57f7dd9d6f2ec12ab9ec2e"
    @finalized "0xdb5c7652857aa163daadd670e116628fb42e869d8ac4251ef8971d9e5727df1b"
    @finalized_blast "0x36d89e6190aa646d1a48286f8ad05e60a144483f42fd7e0ea08baba79343645b"
    @relayed "0x4641df4a962071e12719d8c8c8e5ac7fc4d97b927346a3d7a335b1f7517e133c"
    @failed "0x99d0e048484baa1b1540b1367cb128acd7ab2946d1ed91ec10e3c85e4bf51b8f"

    setup :verify_on_exit!

    setup %{json_rpc_named_arguments: json_rpc_named_arguments} do
      LatestL1BlockNumber.set_block_number(300)
      on_exit(fn -> ConCache.delete(LatestL1BlockNumber.cache_name(), :block_number) end)

      config = Application.get_env(:indexer, MessageRelayL1)
      on_exit(fn -> Application.put_env(:indexer, MessageRelayL1, config) end)

      %{json_rpc_named_arguments: Keyword.put(json_rpc_named_arguments, :transport, EthereumJSONRPC.Mox)}
    end

    defp state(json_rpc_named_arguments) do
      %{
        contract_address: @portal,
        block_check_interval: 12_000,
        start_block: 100,
        end_block: 199,
        json_rpc_named_arguments: json_rpc_named_arguments,
        eth_get_logs_range_size: 250,
        stop: false
      }
    end

    defp hash(n), do: String.downcase("0x" <> String.pad_leading(Integer.to_string(n, 16), 64, "0"))

    defp log(address, topics, transaction_hash, block_number) do
      %{
        "address" => address,
        "topics" => topics,
        "data" => "0x0000000000000000000000000000000000000000000000000000000000000001",
        "transactionHash" => transaction_hash,
        "blockNumber" => "0x" <> Integer.to_string(block_number, 16),
        "logIndex" => "0x0"
      }
    end

    defp insert_finalization(block_number) do
      finalizing_transaction_hash = transaction_hash()

      Repo.insert!(%WithdrawalEventSchema{
        withdrawal_hash: transaction_hash(),
        l1_event_type: :WithdrawalFinalized,
        l1_timestamp: DateTime.add(~U[2026-01-01 00:00:00.000000Z], block_number * 12),
        l1_transaction_hash: finalizing_transaction_hash,
        l1_block_number: block_number
      })

      finalizing_transaction_hash
    end

    describe "handle_info(:continue, state)" do
      # The portal emits `WithdrawalFinalized` with `success = true` even when the messenger fails to deliver the
      # message, so a finalization indexed without its relay would read as delivered until the relay fetcher, which
      # scans the same blocks on its own, reached the transaction.
      test "imports the relay result of a finalizing transaction together with the finalization", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        Application.put_env(:indexer, MessageRelayL1, l1_cross_domain_messenger: @messenger)

        # Block numbers go out through EthereumJSONRPC.integer_to_quantity/1, which writes upper-case hex.
        expect(EthereumJSONRPC.Mox, :json_rpc, 3, fn
          %{
            method: "eth_getLogs",
            params: [
              %{
                address: [@portal, @messenger],
                topics: [[@proven, @proven_blast, @finalized, @finalized_blast, @relayed, @failed]],
                fromBlock: "0x64",
                toBlock: "0xC7"
              }
            ]
          },
          _options ->
            {:ok,
             [
               log(@messenger, [@failed, hash(1)], hash(101), 150),
               log(@portal, [@finalized, hash(2)], hash(101), 150),
               # a replay calls the messenger directly; the relay fetcher indexes it
               log(@messenger, [@relayed, hash(3)], hash(102), 160)
             ]}

          [%{id: id, method: "eth_getBlockByNumber", params: ["0x96", true]}], _options ->
            {:ok, [%{id: id, result: block_response(150)}]}

          [%{id: id, method: "eth_getBlockByNumber", params: ["0xC7", false]}], _options ->
            {:ok, [%{id: id, result: block_response(199)}]}
        end)

        assert {:noreply, %{start_block: 200, end_block: 300}} =
                 WithdrawalEvent.handle_info(:continue, state(json_rpc_named_arguments))

        assert [{withdrawal_hash, :WithdrawalFinalized, finalizing_transaction_hash, 150}] =
                 Repo.all(
                   from(we in WithdrawalEventSchema,
                     select: {we.withdrawal_hash, we.l1_event_type, we.l1_transaction_hash, we.l1_block_number}
                   )
                 )

        assert to_string(withdrawal_hash) == hash(2)
        assert to_string(finalizing_transaction_hash) == hash(101)

        assert [{message_hash, :FailedRelayedMessage, relay_transaction_hash, :l1, 150}] =
                 Repo.all(
                   from(r in MessageRelay,
                     select: {r.message_hash, r.event_type, r.transaction_hash, r.chain, r.block_number}
                   )
                 )

        assert to_string(message_hash) == hash(1)
        assert to_string(relay_transaction_hash) == hash(101)
      end

      test "reads only the portal events without the L1CrossDomainMessenger address", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        Application.put_env(:indexer, MessageRelayL1, l1_cross_domain_messenger: nil)

        expect(EthereumJSONRPC.Mox, :json_rpc, 3, fn
          %{
            method: "eth_getLogs",
            params: [
              %{
                address: @portal,
                topics: [[@proven, @proven_blast, @finalized, @finalized_blast]],
                fromBlock: "0x64",
                toBlock: "0xC7"
              }
            ]
          },
          _options ->
            {:ok, [log(@portal, [@finalized, hash(2)], hash(101), 150)]}

          [%{id: id, method: "eth_getBlockByNumber", params: ["0x96", true]}], _options ->
            {:ok, [%{id: id, result: block_response(150)}]}

          [%{id: id, method: "eth_getBlockByNumber", params: ["0xC7", false]}], _options ->
            {:ok, [%{id: id, result: block_response(199)}]}
        end)

        assert {:noreply, %{start_block: 200, end_block: 300}} =
                 WithdrawalEvent.handle_info(:continue, state(json_rpc_named_arguments))

        assert [:WithdrawalFinalized] =
                 Repo.all(from(we in WithdrawalEventSchema, select: we.l1_event_type))

        assert [] == Repo.all(MessageRelay)
      end
    end

    describe "handle_info(:continue, state) on an L1 reorg" do
      # The relay fetcher may have handled the reorg already, before this fetcher imported the relays of the old fork
      test "removes the relays of the finalizations it removes, and no other relay", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        Application.put_env(:indexer, MessageRelayL1, l1_cross_domain_messenger: @messenger)

        kept = insert(:op_message_relay, chain: :l1, transaction_hash: insert_finalization(110), block_number: 110)
        insert(:op_message_relay, chain: :l1, transaction_hash: insert_finalization(150), block_number: 150)
        # a replay, which the relay fetcher removes on its own
        replay = insert(:op_message_relay, chain: :l1, block_number: 160)

        RollupReorgMonitorQueue.push(120, WithdrawalEvent)

        expect(EthereumJSONRPC.Mox, :json_rpc, fn %{method: "eth_getLogs"}, _options -> {:ok, []} end)

        assert {:noreply, %{start_block: 120}} = WithdrawalEvent.handle_info(:continue, state(json_rpc_named_arguments))

        assert [110] == Repo.all(from(we in WithdrawalEventSchema, select: we.l1_block_number))

        assert Enum.sort([kept.transaction_hash, replay.transaction_hash]) ==
                 Enum.sort(Repo.all(from(r in MessageRelay, select: r.transaction_hash)))
      end
    end

    describe "get_last_l1_item/1" do
      # After a reorg while the indexer was stopped, the events of a block whose transaction is gone are removed on
      # start, before this fetcher resumes from the last event left
      test "removes the relays of the finalizations of a reorged block with its events", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        kept_finalization = insert_finalization(110)
        reorged_finalization = insert_finalization(150)
        kept = insert(:op_message_relay, chain: :l1, transaction_hash: kept_finalization, block_number: 110)
        insert(:op_message_relay, chain: :l1, transaction_hash: reorged_finalization, block_number: 150)

        expect(EthereumJSONRPC.Mox, :json_rpc, 2, fn %{method: "eth_getTransactionByHash", params: [hash]}, _options ->
          if hash == reorged_finalization, do: {:ok, nil}, else: {:ok, %{"hash" => to_string(hash)}}
        end)

        assert {110, ^kept_finalization, %{}} = WithdrawalEvent.get_last_l1_item(json_rpc_named_arguments)
        assert [110] == Repo.all(from(we in WithdrawalEventSchema, select: we.l1_block_number))
        assert [kept.transaction_hash] == Repo.all(from(r in MessageRelay, select: r.transaction_hash))
      end
    end

    # Block object as returned by eth_getBlockByNumber.
    defp block_response(number) do
      %{
        "difficulty" => "0x0",
        "extraData" => "0x",
        "gasLimit" => "0x1c9c380",
        "gasUsed" => "0x0",
        "hash" => hash(number),
        "logsBloom" => "0x" <> String.duplicate("0", 512),
        "miner" => "0x0000000000000000000000000000000000000000",
        "mixHash" => "0x" <> String.duplicate("0", 64),
        "nonce" => "0x0000000000000000",
        "number" => "0x" <> Integer.to_string(number, 16),
        "parentHash" => "0x" <> String.duplicate("0", 64),
        "receiptsRoot" => "0x" <> String.duplicate("0", 64),
        "sha3Uncles" => "0x" <> String.duplicate("0", 64),
        "size" => "0x200",
        "stateRoot" => "0x" <> String.duplicate("0", 64),
        "timestamp" => "0x65f3f6dc",
        "totalDifficulty" => "0x0",
        "transactions" => [],
        "transactionsRoot" => "0x" <> String.duplicate("0", 64),
        "uncles" => []
      }
    end
  end
end
