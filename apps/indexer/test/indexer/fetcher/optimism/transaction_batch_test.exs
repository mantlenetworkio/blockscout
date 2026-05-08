if Application.get_env(:explorer, :chain_type) == :optimism do
  defmodule Indexer.Fetcher.Optimism.TransactionBatchTest do
    use EthereumJSONRPC.Case, async: false
    use Explorer.DataCase

    import Mox

    alias Indexer.Fetcher.Optimism.TransactionBatch

    setup %{json_rpc_named_arguments: json_rpc_named_arguments} do
      mocked_json_rpc_named_arguments = Keyword.put(json_rpc_named_arguments, :transport, EthereumJSONRPC.Mox)

      %{json_rpc_named_arguments: mocked_json_rpc_named_arguments}
    end

    describe "get_block_numbers_by_hashes/2" do
      test "processes empty list" do
        assert TransactionBatch.get_block_numbers_by_hashes([], %{}) == %{}
      end

      test "processes list of hashes", %{json_rpc_named_arguments: json_rpc_named_arguments} do
        hashA = <<1::256>>

        hashB =
          <<48, 120, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32,
            32, 32, 32, 32, 32>>

        hashes = [
          hashA,
          hashB
        ]

        expect(EthereumJSONRPC.Mox, :json_rpc, 1, fn [
                                                       %{
                                                         id: id1,
                                                         method: "eth_getBlockByHash",
                                                         params: [
                                                           %Explorer.Chain.Hash{byte_count: 32, bytes: ^hashA},
                                                           false
                                                         ]
                                                       },
                                                       %{
                                                         id: id2,
                                                         method: "eth_getBlockByHash",
                                                         params: [
                                                           %Explorer.Chain.Hash{byte_count: 32, bytes: ^hashB},
                                                           false
                                                         ]
                                                       }
                                                     ],
                                                     _options ->
          {:ok,
           [
             %{
               id: id1,
               jsonrpc: "2.0",
               result: %{"number" => 1, "hash" => "0x0000000000000000000000000000000000000000000000000000000000000001"}
             },
             %{
               id: id2,
               jsonrpc: "2.0",
               result: %{"number" => 2, "hash" => "0x3078202020202020202020202020202020202020202020202020202020202020"}
             }
           ]}
        end)

        assert %{hashA => 1, hashB => 2} ==
                 TransactionBatch.get_block_numbers_by_hashes(hashes, json_rpc_named_arguments)
      end
    end

    describe "validate_eip4844_blob_hashes/1" do
      test "returns an error when a type-3 transaction has no blob hashes" do
        transaction = %{
          type: 3,
          hash: "0xbe1ac68a3b66a7fab4968105f32227775ce536e4755c55170cde69a63610599e",
          block_number: 2_763_040,
          blob_versioned_hashes: []
        }

        assert {:error, message} = TransactionBatch.validate_eip4844_blob_hashes([transaction])
        assert message =~ "0xbe1ac68a3b66a7fab4968105f32227775ce536e4755c55170cde69a63610599e"
        assert message =~ "blobVersionedHashes"

        transaction_without_blob_field = Map.delete(transaction, :blob_versioned_hashes)

        assert {:error, _message} = TransactionBatch.validate_eip4844_blob_hashes([transaction_without_blob_field])
      end

      test "accepts type-3 transactions with blob hashes" do
        transaction = %{
          type: 3,
          hash: "0xbe1ac68a3b66a7fab4968105f32227775ce536e4755c55170cde69a63610599e",
          block_number: 2_763_040,
          blob_versioned_hashes: ["0x016872b6f80712247d48f10599b335e694741caced92352abc512882c22b2264"]
        }

        assert :ok = TransactionBatch.validate_eip4844_blob_hashes([transaction])
      end
    end
  end
end
