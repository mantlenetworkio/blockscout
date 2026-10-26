defmodule Indexer.Fetcher.Optimism.EIP1559ConfigUpdateTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use EthereumJSONRPC.Case, async: false
    use Explorer.DataCase

    import EthereumJSONRPC, only: [integer_to_quantity: 1, quantity_to_integer: 1]
    import Mox

    alias Indexer.Fetcher.Optimism.EIP1559ConfigUpdate, as: Fetcher

    @latest_block_number 1_000

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
    end

    defp timestamp(number), do: 1_000_001 + 2 * number

    # The block an eth_getBlockByNumber request (by number or by the `latest` tag) asks for, without transactions.
    defp block_response(%{method: "eth_getBlockByNumber", params: [number_or_tag, false]}) do
      number = if number_or_tag == "latest", do: @latest_block_number, else: quantity_to_integer(number_or_tag)
      zero_hash = "0x" <> String.duplicate("0", 64)

      %{
        "difficulty" => "0x0",
        "extraData" => "0x",
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

    defp put_holocene_timestamp(timestamp) do
      Application.put_env(:indexer, Fetcher,
        holocene_timestamp_l2: timestamp,
        jovian_timestamp_l2: nil,
        chunk_size: 25
      )
    end
  end
end
