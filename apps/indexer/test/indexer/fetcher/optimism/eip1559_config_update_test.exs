defmodule Indexer.Fetcher.Optimism.EIP1559ConfigUpdateTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use EthereumJSONRPC.Case, async: false
    use Explorer.DataCase

    import EthereumJSONRPC, only: [integer_to_quantity: 1, quantity_to_integer: 1]
    import ExUnit.CaptureLog, only: [capture_log: 1]
    import Mox

    alias Explorer.Chain.Cache.Counters.LastFetchedCounter
    alias Explorer.Chain.Optimism.EIP1559ConfigUpdate
    alias Explorer.Repo
    alias Indexer.Fetcher.Optimism
    alias Indexer.Fetcher.Optimism.EIP1559ConfigUpdate, as: Fetcher
    alias Indexer.Fetcher.Optimism.TransactionBatch

    @latest_block_number 1_000
    @counter_type "optimism_eip1559_config_updates_fetcher_last_l2_block_hash"

    setup {Mox, :verify_on_exit!}

    # An L2 chain of 1,001 blocks whose block n has the timestamp 1,000,001 + 2n: every block timestamp is odd, as on a
    # chain whose rollup genesis time is an odd number of seconds before its first block.
    setup %{json_rpc_named_arguments: json_rpc_named_arguments} do
      previous = Application.get_env(:indexer, Fetcher)
      on_exit(fn -> Application.put_env(:indexer, Fetcher, previous) end)

      stub(EthereumJSONRPC.Mox, :json_rpc, fn
        requests, _options when is_list(requests) ->
          {:ok, Enum.map(requests, &%{id: &1.id, result: block_response(&1)})}

        request, _options ->
          {:ok, block_response(request)}
      end)

      %{json_rpc_named_arguments: Keyword.put(json_rpc_named_arguments, :transport, EthereumJSONRPC.Mox)}
    end

    describe "handle_continue/2" do
      # An upgrade activates at the first block whose timestamp is at or after its time, which need not be the
      # timestamp of any block. A new database is indexed from the head of the chain down, so its indexed block
      # nearest to the time can be far from it.
      test "starts from the first block after the Holocene time, which no block has", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        index_blocks(990..1_000)
        put_holocene_timestamp(timestamp(400) - 1)

        assert {:noreply, %{start_block_number: 400, end_block_number: @latest_block_number}} =
                 Fetcher.handle_continue(json_rpc_named_arguments, %{})
      end

      test "starts from the block of the Holocene time", %{json_rpc_named_arguments: json_rpc_named_arguments} do
        index_blocks(990..1_000)
        put_holocene_timestamp(timestamp(400))

        assert {:noreply, %{start_block_number: 400, end_block_number: @latest_block_number}} =
                 Fetcher.handle_continue(json_rpc_named_arguments, %{})
      end

      test "starts from the first block when the Holocene time precedes it", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        put_holocene_timestamp(timestamp(0) - 1)

        assert {:noreply, %{start_block_number: 0}} = Fetcher.handle_continue(json_rpc_named_arguments, %{})
      end

      test "starts from the latest block when it has the Holocene time", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        put_holocene_timestamp(timestamp(@latest_block_number))

        assert {:noreply, %{start_block_number: @latest_block_number}} =
                 Fetcher.handle_continue(json_rpc_named_arguments, %{})
      end

      # An L2 node need not keep the blocks of a chain from before its rollup genesis, here blocks 0..599: the Holocene
      # block is counted back from the latest one by the block duration, without reading them
      test "finds the Holocene block without reading the blocks before the rollup genesis", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        stub_blocks_after_genesis(600)
        put_holocene_timestamp(timestamp(800) - 1)

        assert {:noreply, %{start_block_number: 800}} = Fetcher.handle_continue(json_rpc_named_arguments, %{})
      end

      # The count needs blocks spaced by the block duration: the chain is searched for a block it misses
      test "searches the chain for the Holocene block when the block duration does not space the blocks", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        put_block_duration(3)
        put_holocene_timestamp(timestamp(400) - 1)

        assert {:noreply, %{start_block_number: 400}} = Fetcher.handle_continue(json_rpc_named_arguments, %{})
      end

      # The search reads no block before the rollup genesis that INDEXER_OPTIMISM_L2_BATCH_GENESIS_BLOCK_NUMBER gives
      test "searches the chain for the Holocene block from the rollup genesis block", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        stub_blocks_after_genesis(600)
        put_genesis_block(600)
        put_block_duration(3)
        put_holocene_timestamp(timestamp(800) - 1)

        assert {:noreply, %{start_block_number: 800}} = Fetcher.handle_continue(json_rpc_named_arguments, %{})
      end

      test "starts from the rollup genesis block when the Holocene time precedes it", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        stub_blocks_after_genesis(600)
        put_genesis_block(600)
        put_holocene_timestamp(timestamp(0) - 1)

        assert {:noreply, %{start_block_number: 600}} = Fetcher.handle_continue(json_rpc_named_arguments, %{})
      end

      # The Holocene timestamp 0 stands for an upgrade active from the rollup genesis
      test "starts from the rollup genesis block when the Holocene timestamp is 0", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        stub_blocks_after_genesis(600)
        put_genesis_block(600)
        put_holocene_timestamp(0)

        assert {:noreply, %{start_block_number: 600}} = Fetcher.handle_continue(json_rpc_named_arguments, %{})
      end
    end

    describe "handle_info(:continue, state)" do
      # A request of the batch fetching a chunk can fail alone. The parameters a missing block sets would be recorded at
      # a later block, or not at all, as the checkpoint moves past it: the chunk is fetched again instead, with nothing
      # recorded before.
      test "handles a chunk once the RPC node returns all of its blocks", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        extra_data = %{10 => extra_data(250, 6), 11 => extra_data(250, 6), 12 => extra_data(300, 8)}

        expect(EthereumJSONRPC.Mox, :json_rpc, fn requests, _options ->
          {:ok,
           Enum.map(requests, fn %{id: id, params: [quantity, false]} = request ->
             case quantity_to_integer(quantity) do
               12 -> %{id: id, error: %{code: -32_005, message: "limit exceeded"}}
               number -> %{id: id, result: block_response(request, extra_data[number])}
             end
           end)}
        end)

        expect(EthereumJSONRPC.Mox, :json_rpc, fn requests, _options ->
          assert 0 == Repo.aggregate(EIP1559ConfigUpdate, :count)
          assert is_nil(LastFetchedCounter.get(@counter_type, nullable: true))

          {:ok,
           Enum.map(requests, fn %{id: id, params: [quantity, false]} = request ->
             %{id: id, result: block_response(request, extra_data[quantity_to_integer(quantity)])}
           end)}
        end)

        capture_log(fn ->
          assert {:noreply, %{mode: :realtime}} =
                   Fetcher.handle_info(:continue, continue_state(json_rpc_named_arguments, 10, 12))
        end)

        assert [{10, 250, 6}, {12, 300, 8}] ==
                 Repo.all(
                   from(u in EIP1559ConfigUpdate,
                     select: {u.l2_block_number, u.base_fee_max_change_denominator, u.elasticity_multiplier},
                     order_by: u.l2_block_number
                   )
                 )

        assert Optimism.get_last_block_hash(@counter_type) ==
                 block_response(%{method: "eth_getBlockByNumber", params: [integer_to_quantity(12), false]})["hash"]
      end

      # The last handled block is above the latest one at the start, as when the RPC node lags behind the one before
      test "fetches no blocks of a range that ends before it starts", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        stub(EthereumJSONRPC.Mox, :json_rpc, fn request, _options -> flunk("Requested #{inspect(request)}") end)

        capture_log(fn ->
          assert {:noreply, %{mode: :realtime}} =
                   Fetcher.handle_info(:continue, continue_state(json_rpc_named_arguments, 12, 10))
        end)
      end
    end

    defp timestamp(number), do: 1_000_001 + 2 * number

    # The block an eth_getBlockByNumber request (by number or by the `latest` tag) asks for, without transactions.
    defp block_response(%{method: "eth_getBlockByNumber", params: [number_or_tag, false]}, extra_data \\ "0x") do
      number = if number_or_tag == "latest", do: @latest_block_number, else: quantity_to_integer(number_or_tag)
      zero_hash = "0x" <> String.duplicate("0", 64)

      %{
        "difficulty" => "0x0",
        "extraData" => extra_data,
        "gasLimit" => "0x1c9c380",
        "gasUsed" => "0x0",
        "hash" => "0x" <> String.pad_leading(Integer.to_string(number, 16), 64, "0"),
        "logsBloom" => "0x" <> String.duplicate("0", 512),
        "miner" => "0x0000000000000000000000000000000000000000",
        "mixHash" => zero_hash,
        "nonce" => "0x0000000000000000",
        "number" => integer_to_quantity(number),
        "parentHash" => zero_hash,
        "receiptsRoot" => zero_hash,
        "sha3Uncles" => zero_hash,
        "size" => "0x200",
        "stateRoot" => zero_hash,
        "timestamp" => integer_to_quantity(timestamp(number)),
        "totalDifficulty" => "0x0",
        "transactions" => [],
        "transactionsRoot" => zero_hash,
        "uncles" => []
      }
    end

    defp index_blocks(numbers) do
      Enum.each(numbers, &insert(:block, number: &1, timestamp: DateTime.from_unix!(timestamp(&1)), consensus: true))
    end

    # The block a request asks for, failing the test for a block before `first_block_number`, which the L2 node would
    # not have
    defp block_after_genesis(%{params: [number_or_tag, false]} = request, first_block_number) do
      if number_or_tag != "latest" and quantity_to_integer(number_or_tag) < first_block_number do
        flunk("Block #{quantity_to_integer(number_or_tag)}, from before the rollup genesis, was requested")
      end

      block_response(request)
    end

    defp stub_blocks_after_genesis(first_block_number) do
      stub(EthereumJSONRPC.Mox, :json_rpc, fn
        requests, _options when is_list(requests) ->
          {:ok, Enum.map(requests, &%{id: &1.id, result: block_after_genesis(&1, first_block_number)})}

        request, _options ->
          {:ok, block_after_genesis(request, first_block_number)}
      end)
    end

    # `extraData` of a block from Holocene on: version 0, the denominator, and the elasticity
    defp extra_data(denominator, elasticity) do
      "0x" <> Base.encode16(<<0, denominator::size(32), elasticity::size(32)>>, case: :lower)
    end

    defp continue_state(json_rpc_named_arguments, start_block_number, end_block_number) do
      %{
        start_block_number: start_block_number,
        end_block_number: end_block_number,
        chunk_size: 25,
        timestamp: timestamp(0),
        mode: :catchup,
        realtime_range: nil,
        last_realtime_block_number: nil,
        json_rpc_named_arguments: json_rpc_named_arguments
      }
    end

    defp put_block_duration(seconds) do
      previous = Application.get_env(:indexer, Optimism)
      Application.put_env(:indexer, Optimism, Keyword.put(previous || [], :block_duration, seconds))
      on_exit(fn -> Application.put_env(:indexer, Optimism, previous) end)
    end

    # INDEXER_OPTIMISM_L2_BATCH_GENESIS_BLOCK_NUMBER
    defp put_genesis_block(number) do
      previous = Application.get_env(:indexer, TransactionBatch)
      Application.put_env(:indexer, TransactionBatch, Keyword.put(previous || [], :genesis_block_l2, number))
      on_exit(fn -> Application.put_env(:indexer, TransactionBatch, previous) end)
    end

    defp put_holocene_timestamp(timestamp) do
      Application.put_env(:indexer, Fetcher,
        holocene_timestamp_l2: timestamp,
        jovian_timestamp_l2: nil,
        chunk_size: 25
      )
    end
  end
end
