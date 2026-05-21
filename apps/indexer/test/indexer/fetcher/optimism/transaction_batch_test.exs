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

    describe "validate_chain_continuity/3" do
      # `@prev_tail_hash` is what the OP counter stored at the end of the previous chunk;
      # it can be (a) the parent of the new chunk's first block in the normal forward step,
      # or (b) the first block of the new chunk itself in the restart re-scan path where
      # `start_block` is seeded to `last_l1_block_number` (not +1).
      @prev_tail_hash "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      @empty_hash "0x0000000000000000000000000000000000000000000000000000000000000000"

      test "returns :ok when expected_hash is nil (initial seed / no prior chunk)" do
        blocks_params = [%{number: 2_800_657, hash: "0xhash_657", parent_hash: "0xanything"}]
        assert :ok = TransactionBatch.validate_chain_continuity(2_800_657, blocks_params, nil)
      end

      test "returns :ok when expected_hash is the all-zero empty hash" do
        blocks_params = [%{number: 2_800_657, hash: "0xhash_657", parent_hash: "0xanything"}]
        assert :ok = TransactionBatch.validate_chain_continuity(2_800_657, blocks_params, @empty_hash)
      end

      test "forward step: returns :ok when block.parent_hash matches stored hash" do
        # Normal in-process tick: start_block = last_chunk_end + 1, so the new chunk's first
        # block has the stored hash as its parent.
        blocks_params = [
          %{number: 2_800_656, hash: "0xirrelevant", parent_hash: "0xprev_prev"},
          %{number: 2_800_657, hash: "0xhash_657", parent_hash: @prev_tail_hash},
          %{number: 2_800_658, hash: "0xhash_658", parent_hash: "0xhash_657"}
        ]

        assert :ok = TransactionBatch.validate_chain_continuity(2_800_657, blocks_params, @prev_tail_hash)
      end

      test "restart re-scan: returns :ok when block.hash itself matches stored hash" do
        # After pod restart, handle_continue seeds `start_block = max(start_block_l1,
        # last_l1_block_number)` — i.e. the very block whose hash we stored. The first chunk
        # re-scans that boundary block; its `.hash` (not its `.parent_hash`) must equal the
        # stored hash. This case is the reviewer-flagged false-positive scenario.
        blocks_params = [
          %{number: 2_800_657, hash: @prev_tail_hash, parent_hash: "0xprev_block_hash"},
          %{number: 2_800_658, hash: "0xhash_658", parent_hash: @prev_tail_hash}
        ]

        assert :ok = TransactionBatch.validate_chain_continuity(2_800_657, blocks_params, @prev_tail_hash)
      end

      test "matches case-insensitively on both relationships" do
        upper = "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

        # parent_hash match, case-flipped
        forward = [%{number: 2_800_657, hash: "0xhash_657", parent_hash: @prev_tail_hash}]
        assert :ok = TransactionBatch.validate_chain_continuity(2_800_657, forward, upper)

        # block.hash match, case-flipped
        restart = [%{number: 2_800_657, hash: @prev_tail_hash, parent_hash: "0xprev"}]
        assert :ok = TransactionBatch.validate_chain_continuity(2_800_657, restart, upper)
      end

      test "returns {:reorg, chunk_start - 1} when neither hash nor parent_hash matches" do
        blocks_params = [%{number: 2_800_657, hash: "0xdifferent_hash", parent_hash: "0xdifferent_parent"}]

        assert {:reorg, 2_800_656} =
                 TransactionBatch.validate_chain_continuity(2_800_657, blocks_params, @prev_tail_hash)
      end

      test "clamps divergence_block to 0 when chunk_start is 0 (genesis edge case)" do
        blocks_params = [%{number: 0, hash: "0xother", parent_hash: "0xdifferent"}]

        assert {:reorg, 0} = TransactionBatch.validate_chain_continuity(0, blocks_params, @prev_tail_hash)
      end

      test "returns :ok defensively when the chunk-start block is missing from blocks_params" do
        blocks_params = [%{number: 2_800_658, hash: "0xanything", parent_hash: "0xanything"}]

        assert :ok = TransactionBatch.validate_chain_continuity(2_800_657, blocks_params, @prev_tail_hash)
      end

      test "tolerates missing :hash field by falling back to parent_hash check" do
        # Defensive: even if some upstream stripped :hash from the block params, a valid
        # parent_hash should still let the forward step succeed.
        blocks_params = [%{number: 2_800_657, parent_hash: @prev_tail_hash}]

        assert :ok = TransactionBatch.validate_chain_continuity(2_800_657, blocks_params, @prev_tail_hash)
      end
    end
  end
end
