if Application.get_env(:explorer, :chain_type) == :optimism do
  defmodule Indexer.Fetcher.Optimism.MessageRelayL2Test do
    use EthereumJSONRPC.Case, async: false
    use Explorer.DataCase

    import Mox

    alias Explorer.Chain.Optimism.MessageRelay
    alias Explorer.{Repo, TestHelper}
    alias Indexer.Fetcher.Optimism.MessageRelayL2
    alias Indexer.RollupReorgMonitorQueue

    @messenger "0x4200000000000000000000000000000000000007"
    @relayed "0x4641df4a962071e12719d8c8c8e5ac7fc4d97b927346a3d7a335b1f7517e133c"
    @failed "0x99d0e048484baa1b1540b1367cb128acd7ab2946d1ed91ec10e3c85e4bf51b8f"

    setup :verify_on_exit!

    setup %{json_rpc_named_arguments: json_rpc_named_arguments} do
      %{json_rpc_named_arguments: Keyword.put(json_rpc_named_arguments, :transport, EthereumJSONRPC.Mox)}
    end

    defp state(json_rpc_named_arguments) do
      %{
        start_block_number: 1_000,
        end_block_number: 1_099,
        chunk_size: 250,
        mode: :catchup,
        realtime_range: nil,
        last_realtime_block_number: nil,
        messenger: @messenger,
        json_rpc_named_arguments: json_rpc_named_arguments
      }
    end

    defp hash(n), do: String.downcase("0x" <> String.pad_leading(Integer.to_string(n, 16), 64, "0"))

    defp log(signature, message_hash, transaction_hash, block_number) do
      %{
        "address" => @messenger,
        "topics" => [signature, message_hash],
        "data" => "0x",
        "transactionHash" => transaction_hash,
        "blockNumber" => "0x" <> Integer.to_string(block_number, 16),
        "logIndex" => "0x0"
      }
    end

    describe "handle_info(:continue, state)" do
      test "imports the deposit relays of the range and switches to realtime mode", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        # Block numbers go out through EthereumJSONRPC.integer_to_quantity/1, which writes upper-case hex.
        expect(EthereumJSONRPC.Mox, :json_rpc, fn
          %{
            method: "eth_getLogs",
            params: [%{address: @messenger, topics: [[@relayed, @failed]], fromBlock: "0x3E8", toBlock: "0x44B"}]
          },
          _options ->
            {:ok, [log(@failed, hash(1), hash(201), 1_010), log(@relayed, hash(1), hash(202), 1_015)]}
        end)

        assert {:noreply, %{mode: :realtime}} = MessageRelayL2.handle_info(:continue, state(json_rpc_named_arguments))

        assert [{:l2, :FailedRelayedMessage, 1_010}, {:l2, :RelayedMessage, 1_015}] =
                 Repo.all(
                   from(r in MessageRelay, order_by: r.block_number, select: {r.chain, r.event_type, r.block_number})
                 )
      end

      test "on an L2 reorg removes only the L2 relays from the reorg block on and rescans from there", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        insert(:op_message_relay, chain: :l2, block_number: 1_020)
        insert(:op_message_relay, chain: :l2, block_number: 1_050)
        insert(:op_message_relay, chain: :l1, block_number: 1_050)
        RollupReorgMonitorQueue.push(1_040, MessageRelayL2)

        expect(EthereumJSONRPC.Mox, :json_rpc, fn %{method: "eth_getLogs"}, _options -> {:ok, []} end)

        assert {:noreply, %{start_block_number: 1_040, end_block_number: 1_040}} =
                 MessageRelayL2.handle_info(:continue, state(json_rpc_named_arguments))

        assert [{:l1, 1_050}, {:l2, 1_020}] =
                 Repo.all(
                   from(r in MessageRelay, order_by: [r.chain, r.block_number], select: {r.chain, r.block_number})
                 )
      end

      test "walks a catchup range of millions of blocks without building it in memory", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        # a reorg at the start block ends the loop after the first chunk
        RollupReorgMonitorQueue.push(1, MessageRelayL2)
        expect(EthereumJSONRPC.Mox, :json_rpc, fn %{method: "eth_getLogs"}, _options -> {:ok, []} end)

        state = %{
          state(json_rpc_named_arguments)
          | start_block_number: 1,
            end_block_number: 50_000_000,
            chunk_size: 1_000
        }

        task =
          Task.async(fn ->
            # 2M words (16 MB) are plenty for one chunk and far too little for 50M block numbers in lists
            Process.flag(:max_heap_size, %{size: 2_000_000, kill: true, error_logger: false})
            MessageRelayL2.handle_info(:continue, state)
          end)

        assert {:noreply, %{start_block_number: 1, end_block_number: 1}} = Task.await(task)
      end

      test "follows the realtime blocks once the catchup is done", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        realtime_state = %{state(json_rpc_named_arguments) | mode: :realtime, last_realtime_block_number: 1_099}
        new_blocks = [%{number: 1_100}, %{number: 1_101}]

        assert {:noreply, %{start_block_number: 1_100, end_block_number: 1_101, mode: :continue} = next_state} =
                 MessageRelayL2.handle_info({:chain_event, :blocks, :realtime, new_blocks}, realtime_state)

        expect(EthereumJSONRPC.Mox, :json_rpc, fn
          %{method: "eth_getLogs", params: [%{fromBlock: "0x44C", toBlock: "0x44D"}]}, _options ->
            {:ok, [log(@failed, hash(7), hash(207), 1_101)]}
        end)

        assert {:noreply, %{mode: :realtime}} = MessageRelayL2.handle_info(:continue, next_state)

        assert [{:l2, :FailedRelayedMessage, 1_101}] =
                 Repo.all(from(r in MessageRelay, select: {r.chain, r.event_type, r.block_number}))
      end
    end

    describe "get_last_block_number/1" do
      test "is 0 without L2 relays", %{json_rpc_named_arguments: json_rpc_named_arguments} do
        insert(:op_message_relay, chain: :l1, block_number: 700)

        assert {:ok, 0} = MessageRelayL2.get_last_block_number(json_rpc_named_arguments)
      end

      test "drops a relay block whose transaction is gone and resumes from the previous relay", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        insert(:op_message_relay, chain: :l2, block_number: 500, transaction_hash: TestHelper.topic(hash(301)))
        insert(:op_message_relay, chain: :l2, block_number: 600, transaction_hash: TestHelper.topic(hash(302)))

        expect(EthereumJSONRPC.Mox, :json_rpc, 2, fn
          %{method: "eth_getTransactionByHash", params: [transaction_hash]}, _options ->
            if to_string(transaction_hash) == hash(302),
              do: {:ok, nil},
              else: {:ok, %{"hash" => to_string(transaction_hash)}}
        end)

        assert {:ok, 500} = MessageRelayL2.get_last_block_number(json_rpc_named_arguments)
        assert Repo.aggregate(MessageRelay, :count) == 1
      end

      test "leaves alone the v1 relays the legacy backfill writes, which the node may not serve", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        legacy = Application.get_env(:indexer, Indexer.Fetcher.Optimism.LegacyBridge)

        Application.put_env(
          :indexer,
          Indexer.Fetcher.Optimism.LegacyBridge,
          Keyword.merge(legacy || [], l2_end_block: 1_000, l1_end_block: 10_000)
        )

        on_exit(fn -> Application.put_env(:indexer, Indexer.Fetcher.Optimism.LegacyBridge, legacy) end)
        insert(:op_message_relay, chain: :l2, block_number: 900)

        # no eth_getTransactionByHash expected: a v1 relay is never taken for a reorged one
        assert {:ok, 0} = MessageRelayL2.get_last_block_number(json_rpc_named_arguments)
        assert Repo.aggregate(MessageRelay, :count) == 1
      end
    end
  end
end
