if Application.get_env(:explorer, :chain_type) == :optimism do
  defmodule Indexer.Fetcher.Optimism.MessageRelayL1Test do
    use EthereumJSONRPC.Case, async: false
    use Explorer.DataCase

    import ExUnit.CaptureLog
    import Mox

    alias Explorer.Chain.Cache.LatestL1BlockNumber
    alias Explorer.Chain.Optimism.MessageRelay
    alias Explorer.Repo
    alias Indexer.Fetcher.Optimism.MessageRelayL1
    alias Indexer.RollupReorgMonitorQueue

    @messenger "0x37dac5312e31adb8bb0802fc72ca84da5cdfcb4c"
    @relayed "0x4641df4a962071e12719d8c8c8e5ac7fc4d97b927346a3d7a335b1f7517e133c"
    @failed "0x99d0e048484baa1b1540b1367cb128acd7ab2946d1ed91ec10e3c85e4bf51b8f"

    setup :verify_on_exit!

    setup %{json_rpc_named_arguments: json_rpc_named_arguments} do
      LatestL1BlockNumber.set_block_number(300)
      on_exit(fn -> ConCache.delete(LatestL1BlockNumber.cache_name(), :block_number) end)

      %{json_rpc_named_arguments: Keyword.put(json_rpc_named_arguments, :transport, EthereumJSONRPC.Mox)}
    end

    defp state(json_rpc_named_arguments) do
      %{
        contract_address: @messenger,
        block_check_interval: 12_000,
        start_block: 100,
        end_block: 199,
        json_rpc_named_arguments: json_rpc_named_arguments,
        eth_get_logs_range_size: 250,
        stop: false
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

    describe "handle_continue/2" do
      test "does not start without the L1CrossDomainMessenger address" do
        log =
          capture_log(fn ->
            assert {:stop, :normal, %{}} = MessageRelayL1.handle_continue(:ok, %{})
          end)

        assert log =~ "INDEXER_OPTIMISM_L1_CROSS_DOMAIN_MESSENGER_CONTRACT"
      end
    end

    describe "handle_info(:continue, state)" do
      test "imports the messenger relays of the range and moves on", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        # Block numbers go out through EthereumJSONRPC.integer_to_quantity/1, which writes upper-case hex.
        expect(EthereumJSONRPC.Mox, :json_rpc, 2, fn
          %{
            method: "eth_getLogs",
            params: [%{address: @messenger, topics: [[@relayed, @failed]], fromBlock: "0x64", toBlock: "0xC7"}]
          },
          _options ->
            {:ok, [log(@failed, hash(1), hash(101), 150), log(@relayed, hash(1), hash(102), 160)]}

          [%{id: id, method: "eth_getBlockByNumber", params: ["0xC7", false]}], _options ->
            {:ok, [%{id: id, result: block_response(199)}]}
        end)

        assert {:noreply, %{start_block: 200, end_block: 300}} =
                 MessageRelayL1.handle_info(:continue, state(json_rpc_named_arguments))

        assert [{:l1, :FailedRelayedMessage, 150}, {:l1, :RelayedMessage, 160}] =
                 Repo.all(
                   from(r in MessageRelay, order_by: r.block_number, select: {r.chain, r.event_type, r.block_number})
                 )
      end

      test "on an L1 reorg removes only the L1 relays from the reorg block on", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        insert(:op_message_relay, chain: :l1, block_number: 110)
        insert(:op_message_relay, chain: :l1, block_number: 150)
        insert(:op_message_relay, chain: :l2, block_number: 150)
        RollupReorgMonitorQueue.push(120, MessageRelayL1)

        expect(EthereumJSONRPC.Mox, :json_rpc, fn %{method: "eth_getLogs"}, _options -> {:ok, []} end)

        assert {:noreply, %{start_block: 120}} = MessageRelayL1.handle_info(:continue, state(json_rpc_named_arguments))

        assert [{:l1, 110}, {:l2, 150}] =
                 Repo.all(
                   from(r in MessageRelay, order_by: [r.chain, r.block_number], select: {r.chain, r.block_number})
                 )
      end
    end

    # Block object as returned by eth_getBlockByNumber with hydrated transactions off.
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
