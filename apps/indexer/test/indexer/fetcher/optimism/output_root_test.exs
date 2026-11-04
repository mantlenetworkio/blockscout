if Application.get_env(:explorer, :chain_type) == :optimism do
  defmodule Indexer.Fetcher.Optimism.OutputRootTest do
    use EthereumJSONRPC.Case, async: false
    use Explorer.DataCase

    import Mox

    alias Explorer.Application.Constants
    alias Explorer.Chain.Cache.LatestL1BlockNumber
    alias Explorer.Chain.Optimism.OutputRoot
    alias Indexer.Fetcher.Optimism.OutputRoot, as: OutputRootFetcher

    @oracle "0x31d543e7be1da6efdc2206ef7822879045b9f481"

    setup :verify_on_exit!

    setup %{json_rpc_named_arguments: json_rpc_named_arguments} do
      %{json_rpc_named_arguments: Keyword.put(json_rpc_named_arguments, :transport, EthereumJSONRPC.Mox)}
    end

    describe "refresh_l1_heads/2" do
      test "stores the safe and finalized block numbers", %{json_rpc_named_arguments: json_rpc_named_arguments} do
        expect(EthereumJSONRPC.Mox, :json_rpc, 2, fn
          [%{id: id, method: "eth_getBlockByNumber", params: ["safe", false]}], _options ->
            {:ok, [%{id: id, result: block_response(1_100)}]}

          [%{id: id, method: "eth_getBlockByNumber", params: ["finalized", false]}], _options ->
            {:ok, [%{id: id, result: block_response(1_050)}]}
        end)

        assert :ok = OutputRootFetcher.refresh_l1_heads(json_rpc_named_arguments, 1)
        assert Constants.get_constant_value(OutputRoot.l1_safe_block_number_constant()) == "1100"
        assert Constants.get_constant_value(OutputRoot.l1_finalized_block_number_constant()) == "1050"
      end

      test "keeps the stored values when the RPC fails", %{json_rpc_named_arguments: json_rpc_named_arguments} do
        Constants.set_constant_value(OutputRoot.l1_safe_block_number_constant(), "900")
        Constants.set_constant_value(OutputRoot.l1_finalized_block_number_constant(), "800")

        expect(EthereumJSONRPC.Mox, :json_rpc, 2, fn _requests, _options -> {:error, :timeout} end)

        assert :ok = OutputRootFetcher.refresh_l1_heads(json_rpc_named_arguments, 1)
        assert Constants.get_constant_value(OutputRoot.l1_safe_block_number_constant()) == "900"
        assert Constants.get_constant_value(OutputRoot.l1_finalized_block_number_constant()) == "800"
      end
    end

    describe "store_starting_block_number/3" do
      test "reads startingBlockNumber() once and stores it", %{json_rpc_named_arguments: json_rpc_named_arguments} do
        expect(EthereumJSONRPC.Mox, :json_rpc, fn
          %{id: _id, method: "eth_call", params: [%{data: "0x70872aa5", to: @oracle}, "latest"]}, _options ->
            {:ok, "0x0000000000000000000000000000000000000000000000000000000003a568ea"}
        end)

        assert :ok = OutputRootFetcher.store_starting_block_number(@oracle, json_rpc_named_arguments, 1)
        assert Constants.get_constant_value(OutputRoot.starting_block_number_constant()) == "61171946"

        # Already stored: no further RPC call (the expectation above allows exactly one).
        assert :ok = OutputRootFetcher.store_starting_block_number(@oracle, json_rpc_named_arguments, 1)
      end

      test "returns :error and stores nothing when the call fails", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        expect(EthereumJSONRPC.Mox, :json_rpc, fn _request, _options -> {:error, :timeout} end)

        assert :error = OutputRootFetcher.store_starting_block_number(@oracle, json_rpc_named_arguments, 1)
        assert Constants.get_constant_value(OutputRoot.starting_block_number_constant()) == nil
      end

      test "returns :error and stores nothing when the oracle address has no code", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        expect(EthereumJSONRPC.Mox, :json_rpc, fn %{method: "eth_call"}, _options -> {:ok, "0x"} end)

        assert :error = OutputRootFetcher.store_starting_block_number(@oracle, json_rpc_named_arguments, 1)
        assert Constants.get_constant_value(OutputRoot.starting_block_number_constant()) == nil
      end
    end

    describe "refresh_finalization_period/3" do
      test "stores FINALIZATION_PERIOD_SECONDS()", %{json_rpc_named_arguments: json_rpc_named_arguments} do
        expect(EthereumJSONRPC.Mox, :json_rpc, fn
          %{method: "eth_call", params: [%{data: "0xf4daa291", to: @oracle}, "latest"]}, _options ->
            {:ok, "0x000000000000000000000000000000000000000000000000000000000000a8c0"}
        end)

        assert :ok = OutputRootFetcher.refresh_finalization_period(@oracle, json_rpc_named_arguments, 1)
        assert Constants.get_constant_value(OutputRoot.finalization_period_constant()) == "43200"
      end

      test "keeps the stored value when the call fails or the oracle has no code", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        Constants.set_constant_value(OutputRoot.finalization_period_constant(), "3600")

        expect(EthereumJSONRPC.Mox, :json_rpc, 1, fn %{method: "eth_call"}, _options -> {:error, :timeout} end)
        assert :ok = OutputRootFetcher.refresh_finalization_period(@oracle, json_rpc_named_arguments, 1)

        expect(EthereumJSONRPC.Mox, :json_rpc, 1, fn %{method: "eth_call"}, _options -> {:ok, "0x"} end)
        assert :ok = OutputRootFetcher.refresh_finalization_period(@oracle, json_rpc_named_arguments, 1)

        assert Constants.get_constant_value(OutputRoot.finalization_period_constant()) == "3600"
      end
    end

    describe "handle_info(:continue, state)" do
      setup do
        LatestL1BlockNumber.set_block_number(1_200)
        on_exit(fn -> ConCache.delete(LatestL1BlockNumber.cache_name(), :block_number) end)
      end

      test "stores the starting block once and refreshes the L1 heads and the period at most once per interval", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        expect(EthereumJSONRPC.Mox, :json_rpc, 4, fn
          %{method: "eth_call", params: [%{data: "0x70872aa5", to: @oracle}, "latest"]}, _options ->
            {:ok, "0x0000000000000000000000000000000000000000000000000000000003a568ea"}

          %{method: "eth_call", params: [%{data: "0xf4daa291", to: @oracle}, "latest"]}, _options ->
            {:ok, "0x000000000000000000000000000000000000000000000000000000000000a8c0"}

          [%{id: id, method: "eth_getBlockByNumber", params: ["safe", false]}], _options ->
            {:ok, [%{id: id, result: block_response(1_100)}]}

          [%{id: id, method: "eth_getBlockByNumber", params: ["finalized", false]}], _options ->
            {:ok, [%{id: id, result: block_response(1_050)}]}
        end)

        # Nothing new on L1 (start_block > end_block), so the iteration only does the bookkeeping under test.
        state = %{
          contract_address: @oracle,
          block_check_interval: :timer.minutes(10),
          start_block: 1_201,
          end_block: 1_200,
          json_rpc_named_arguments: json_rpc_named_arguments,
          eth_get_logs_range_size: 1_000,
          stop: false
        }

        assert {:noreply, state} = OutputRootFetcher.handle_info(:continue, state)
        assert Constants.get_constant_value(OutputRoot.starting_block_number_constant()) == "61171946"
        assert Constants.get_constant_value(OutputRoot.l1_safe_block_number_constant()) == "1100"
        assert Constants.get_constant_value(OutputRoot.l1_finalized_block_number_constant()) == "1050"
        assert Constants.get_constant_value(OutputRoot.finalization_period_constant()) == "43200"

        # The next iteration within block_check_interval makes no further RPC call: the expectation allows four.
        assert {:noreply, _state} = OutputRootFetcher.handle_info(:continue, state)
      end
    end

    describe "events_to_output_roots/1" do
      # Mantle Sepolia deleted outputs at L1 5060650 and proposed indexes 2976..3001 again; 2996 at 5060617 and 5060716.
      test "keeps only the latest proposal of an index proposed again in the same chunk, so that the chunk imports" do
        events = [
          output_proposed_event(2_996, 1_678_859, 5_060_617, 3, String.duplicate("aa", 32)),
          output_proposed_event(2_997, 1_679_309, 5_060_620, 0, String.duplicate("cc", 32)),
          output_proposed_event(2_996, 1_678_859, 5_060_716, 7, String.duplicate("bb", 32))
        ]

        roots = OutputRootFetcher.events_to_output_roots(events)

        assert roots |> Enum.map(& &1.l2_output_index) |> Enum.sort() == [2_996, 2_997]

        assert %{l1_block_number: 5_060_716, output_root: "0x" <> root} =
                 Enum.find(roots, &(&1.l2_output_index == 2_996))

        assert root == String.duplicate("bb", 32)

        assert {:ok, _} = Explorer.Chain.import(%{optimism_output_roots: %{params: roots}, timeout: :infinity})
        assert Repo.aggregate(OutputRoot, :count) == 2
      end

      test "orders by block and log index whatever the order of the logs" do
        events = [
          output_proposed_event(11, 150, 2_100, 0, String.duplicate("dd", 32)),
          output_proposed_event(10, 100, 2_000, 1, String.duplicate("bb", 32)),
          output_proposed_event(10, 100, 2_000, 0, String.duplicate("aa", 32)),
          output_proposed_event(11, 150, 2_050, 4, String.duplicate("cc", 32))
        ]

        roots = OutputRootFetcher.events_to_output_roots(events)

        assert Enum.map(roots, &{&1.l2_output_index, &1.output_root}) == [
                 {10, "0x" <> String.duplicate("bb", 32)},
                 {11, "0x" <> String.duplicate("dd", 32)}
               ]
      end
    end

    # OutputProposed(bytes32 indexed outputRoot, uint256 indexed l2OutputIndex, uint256 indexed l2BlockNumber,
    # uint256 l1Timestamp) log as returned by eth_getLogs.
    defp output_proposed_event(index, l2_block_number, l1_block_number, log_index, root_hex) do
      %{
        "address" => @oracle,
        "blockNumber" => "0x" <> Integer.to_string(l1_block_number, 16),
        "logIndex" => "0x" <> Integer.to_string(log_index, 16),
        "transactionHash" =>
          "0x" <> String.pad_leading(Integer.to_string(l1_block_number * 10 + log_index, 16), 64, "0"),
        "data" => "0x" <> String.pad_leading(Integer.to_string(1_702_200_000, 16), 64, "0"),
        "topics" => [
          "0xa7aaf2512769da4e444e3de247be2564225c2e7a8f74cfe528e46e17d24868e2",
          "0x" <> root_hex,
          "0x" <> String.pad_leading(Integer.to_string(index, 16), 64, "0"),
          "0x" <> String.pad_leading(Integer.to_string(l2_block_number, 16), 64, "0")
        ]
      }
    end

    # Block object as returned by eth_getBlockByNumber with hydrated transactions off.
    defp block_response(number) do
      %{
        "difficulty" => "0x0",
        "extraData" => "0x",
        "gasLimit" => "0x1c9c380",
        "gasUsed" => "0x0",
        "hash" => "0x" <> String.pad_leading(Integer.to_string(number, 16), 64, "0"),
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
