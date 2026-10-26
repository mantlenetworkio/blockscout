if Application.get_env(:explorer, :chain_type) == :optimism do
  defmodule Indexer.Fetcher.Optimism.TransactionBatchTest do
    use EthereumJSONRPC.Case, async: false
    use Explorer.DataCase

    import EthereumJSONRPC, only: [quantity_to_integer: 1]
    import ExUnit.CaptureLog, only: [capture_log: 1]
    import Mox

    alias Indexer.Fetcher.Optimism.TransactionBatch
    alias Varint.LEB128

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

    describe "unwrap_mantle_blob_inputs/3" do
      @blob_a "0x01" <> String.duplicate("aa", 31)
      @blob_b "0x01" <> String.duplicate("bb", 31)

      # Mantle's op-node decodes blobs as standard ones for good from the first standard blob after Arsia
      setup do
        previous = Application.get_env(:indexer, TransactionBatch)
        Application.put_env(:indexer, TransactionBatch, Keyword.merge(previous || [], mantle_blobs_end_block: 1_000))
        on_exit(fn -> Application.put_env(:indexer, TransactionBatch, previous) end)
      end

      # Mantle's batcher, before Arsia, joined the data of a transaction's blobs into one RLP list of frame data
      test "splits the joined data of a transaction's blobs into the frame data of its RLP list" do
        first = <<0>> <> :crypto.strong_rand_bytes(40)
        second = <<0>> <> :crypto.strong_rand_bytes(60)
        <<head::binary-size(50), tail::binary>> = ExRLP.encode([first, second])

        assert [
                 %{bytes: ^first, eip4844_blob_hash: @blob_a, eip4844_blob_hashes: [@blob_a, @blob_b]},
                 %{bytes: ^second, eip4844_blob_hash: @blob_a, eip4844_blob_hashes: [@blob_a, @blob_b]}
               ] =
                 TransactionBatch.unwrap_mantle_blob_inputs(
                   [%{bytes: head, eip4844_blob_hash: @blob_a}, %{bytes: tail, eip4844_blob_hash: @blob_b}],
                   [@blob_a, @blob_b],
                   999
                 )
      end

      # the data of a standard blob starts with the derivation version 0, which is no RLP list
      test "keeps the inputs of standard blobs" do
        inputs = [%{bytes: <<0>> <> :crypto.strong_rand_bytes(40), eip4844_blob_hash: @blob_a}]

        assert inputs == TransactionBatch.unwrap_mantle_blob_inputs(inputs, [@blob_a], 999)
      end

      # the joined data cannot be decoded without every blob; the missing one is fetched again later
      test "keeps the inputs when a blob of the transaction is missing" do
        <<head::binary-size(50), _tail::binary>> =
          ExRLP.encode([<<0>> <> :crypto.strong_rand_bytes(40), <<0>> <> :crypto.strong_rand_bytes(60)])

        inputs = [%{bytes: head, eip4844_blob_hash: @blob_a}]

        assert inputs == TransactionBatch.unwrap_mantle_blob_inputs(inputs, [@blob_a, @blob_b], 999)
      end

      # as op-node decodes it: the whole data, and a list of byte strings only
      test "keeps the inputs when the joined data is not one RLP list of byte strings" do
        frame = <<0>> <> :crypto.strong_rand_bytes(40)

        for data <- [ExRLP.encode([frame]) <> <<1>>, ExRLP.encode([frame, [frame]])] do
          inputs = [%{bytes: data, eip4844_blob_hash: @blob_a}]

          assert inputs == TransactionBatch.unwrap_mantle_blob_inputs(inputs, [@blob_a], 999)
        end
      end

      # after the switch, op-node takes such data as a standard blob's, and leaves it out
      test "keeps the inputs of a transaction from INDEXER_OPTIMISM_L1_BATCH_MANTLE_BLOBS_END_BLOCK on" do
        inputs = [%{bytes: ExRLP.encode([<<0>> <> :crypto.strong_rand_bytes(40)]), eip4844_blob_hash: @blob_a}]

        assert inputs == TransactionBatch.unwrap_mantle_blob_inputs(inputs, [@blob_a], 1_000)
      end

      test "keeps the inputs when INDEXER_OPTIMISM_L1_BATCH_MANTLE_BLOBS_END_BLOCK is not set" do
        Application.put_env(
          :indexer,
          TransactionBatch,
          Keyword.delete(Application.get_env(:indexer, TransactionBatch), :mantle_blobs_end_block)
        )

        inputs = [%{bytes: ExRLP.encode([<<0>> <> :crypto.strong_rand_bytes(40)]), eip4844_blob_hash: @blob_a}]

        assert inputs == TransactionBatch.unwrap_mantle_blob_inputs(inputs, [@blob_a], 999)
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

    describe "parse_frame_sequence/5" do
      setup {Mox, :verify_on_exit!}

      setup do
        previous = Application.get_env(:indexer, TransactionBatch)

        Application.put_env(
          :indexer,
          TransactionBatch,
          Keyword.merge(previous || [], parent_check_attempts: 3, parent_check_interval: 50)
        )

        on_exit(fn -> Application.put_env(:indexer, TransactionBatch, previous) end)
      end

      # Mantle Sepolia: its rollup genesis time (`genesis.l2_time`, 1702194288) is 1803 seconds before the timestamp of
      # its genesis block, L2 block 325709. Span batches count from the genesis time, so each starts an odd number of
      # seconds after it. Block 36438664 has the timestamp 1774422001 and follows block 36438663, 0x82e703c2….
      @sepolia_span_params {325_709, 2, 1803}
      @sepolia_parent "0x82e703c2fde791ed2535a43d75fb23f229164cee525c2abbf61d18d0ff658db8"
      @l1_timestamp ~U[2026-03-25 07:03:00Z]

      test "maps a span batch to its L2 blocks, counting its timestamp from the rollup genesis time", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        expect_block_hash(36_438_663, @sepolia_parent)
        channel = span_batch_channel(1_774_422_001 - 1_702_194_288, @sepolia_parent, 3)

        assert [36_438_664, 36_438_665, 36_438_666] ==
                 channel
                 |> TransactionBatch.parse_frame_sequence(
                   7,
                   @l1_timestamp,
                   @sepolia_span_params,
                   json_rpc_named_arguments
                 )
                 |> Enum.map(fn %{l2_block_number: number, frame_sequence_id: 7, l1_timestamp: @l1_timestamp} ->
                   number
                 end)
      end

      # A span batch whose parent does not match the safe block before the blocks it maps to: the genesis settings do
      # not match the rollup config (here the genesis block number left at 0), or the batch is invalid
      test "leaves out a span batch that does not follow the safe block before its mapped blocks", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        expect_block_hash(36_112_954, "0x" <> String.duplicate("11", 32))
        expect_safe_block(36_200_000)
        expect_block_hash(36_112_954, "0x" <> String.duplicate("11", 32))
        channel = span_batch_channel(1_774_422_001 - 1_702_194_288, @sepolia_parent, 3)

        log =
          capture_log(fn ->
            assert [] ==
                     TransactionBatch.parse_frame_sequence(
                       channel,
                       7,
                       @l1_timestamp,
                       {0, 2, 1803},
                       json_rpc_named_arguments
                     )
          end)

        assert log =~ "INDEXER_OPTIMISM_L2_BATCH_GENESIS_BLOCK_NUMBER"
      end

      # Without the genesis time offset, every Mantle Sepolia span batch starts between two blocks
      test "leaves out a span batch that starts between two blocks", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        channel = span_batch_channel(1_774_422_001 - 1_702_194_288, @sepolia_parent, 3)

        log =
          capture_log(fn ->
            assert [] ==
                     TransactionBatch.parse_frame_sequence(
                       channel,
                       7,
                       @l1_timestamp,
                       {325_709, 2, 0},
                       json_rpc_named_arguments
                     )
          end)

        assert log =~ "INDEXER_OPTIMISM_L2_BATCH_GENESIS_L2_TIME"
      end

      test "maps a span batch of a chain whose rollup genesis time is the genesis block's timestamp", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        parent = "0x" <> String.duplicate("ab", 32)
        expect_block_hash(9, parent)

        assert [10, 11] ==
                 20
                 |> span_batch_channel(parent, 2)
                 |> TransactionBatch.parse_frame_sequence(7, @l1_timestamp, {0, 2, 0}, json_rpc_named_arguments)
                 |> Enum.map(& &1.l2_block_number)
      end

      # A lagging L2 node does not have the parent yet, or fails to return it: the span batch waits for it instead of
      # being left out for good
      test "waits for the parent of a span batch that the L2 node does not return yet", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        expect(EthereumJSONRPC.Mox, :json_rpc, fn [%{id: id, method: "eth_getBlockByNumber"}], _options ->
          {:ok, [%{id: id, error: %{code: -32_000, message: "header not found"}}]}
        end)

        expect(EthereumJSONRPC.Mox, :json_rpc, fn [%{id: id, method: "eth_getBlockByNumber"}], _options ->
          {:ok, [%{id: id, result: nil}]}
        end)

        expect_block_hash(36_438_663, @sepolia_parent)

        assert [36_438_664, 36_438_665, 36_438_666] == parse_sepolia_span(json_rpc_named_arguments)
      end

      # Two span batches of a channel: the first one's parent comes at once and stays checked, the second one's parent
      # is asked for again alone
      test "checks again only the span batches whose parent the L2 node does not return yet", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        first_parent = "0x" <> String.duplicate("aa", 32)
        second_parent = "0x" <> String.duplicate("bb", 32)

        expect(EthereumJSONRPC.Mox, :json_rpc, fn requests, _options ->
          assert [9, 19] == Enum.map(requests, fn %{params: [quantity, false]} -> quantity_to_integer(quantity) end)

          {:ok,
           [
             %{id: Enum.at(requests, 1).id, result: nil},
             %{id: Enum.at(requests, 0).id, result: %{"number" => "0x9", "hash" => first_parent}}
           ]}
        end)

        expect_block_hash(19, second_parent)

        channel =
          :zlib.compress(
            ExRLP.encode(span_batch(20, first_parent, 10)) <> ExRLP.encode(span_batch(40, second_parent, 2))
          )

        assert Enum.to_list(10..19) ++ [20, 21] ==
                 channel
                 |> TransactionBatch.parse_frame_sequence(7, @l1_timestamp, {0, 2, 0}, json_rpc_named_arguments)
                 |> Enum.map(& &1.l2_block_number)
      end

      # Two span batches of a channel start at the same block with different parents: only the one following the safe
      # block maps to it
      test "maps only the span batch that follows the block, of two that start at it", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        parent = "0x" <> String.duplicate("aa", 32)
        expect_block_hash(9, parent)
        expect_safe_block(100)
        expect_block_hash(9, parent)

        channel =
          :zlib.compress(
            ExRLP.encode(span_batch(20, "0x" <> String.duplicate("cc", 32), 10)) <>
              ExRLP.encode(span_batch(20, parent, 10))
          )

        capture_log(fn ->
          send(
            self(),
            {:blocks,
             TransactionBatch.parse_frame_sequence(channel, 7, @l1_timestamp, {0, 2, 0}, json_rpc_named_arguments)}
          )
        end)

        assert_received {:blocks, blocks}
        assert Enum.to_list(10..19) == Enum.map(blocks, & &1.l2_block_number)
      end

      # Derivation can replace the unsafe parent and make it safe between the reading of the parent and of the safe
      # block: the parent is read again once the safe block is known
      test "reads a mismatching parent again after the safe block before leaving its span batch out", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        expect_block_hash(36_438_663, "0x" <> String.duplicate("22", 32))
        expect_safe_block(36_438_700)
        expect_block_hash(36_438_663, @sepolia_parent)

        assert [36_438_664, 36_438_665, 36_438_666] == parse_sepolia_span(json_rpc_named_arguments)
      end

      # An L2 node that does not answer is waited for, as by the other L2 requests: the checks of a span batch are for a
      # node that answers without its parent
      test "waits for an L2 node that does not answer, without spending the checks of a span batch", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        expect(EthereumJSONRPC.Mox, :json_rpc, 4, fn [%{method: "eth_getBlockByNumber"}], _options ->
          {:error, :timeout}
        end)

        expect_block_hash(36_438_663, @sepolia_parent)

        capture_log(fn -> send(self(), {:blocks, parse_sepolia_span(json_rpc_named_arguments)}) end)

        assert_received {:blocks, [36_438_664, 36_438_665, 36_438_666]}
      end

      # The confirming read of a mismatching parent is waited for as well while the L2 node does not answer
      test "waits for an L2 node that does not answer the confirming read of a mismatching parent", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        unsafe_parent = "0x" <> String.duplicate("22", 32)

        for _ <- 1..3 do
          expect_block_hash(36_438_663, unsafe_parent)
          expect_safe_block(36_438_600)

          expect(EthereumJSONRPC.Mox, :json_rpc, fn [%{method: "eth_getBlockByNumber"}], _options ->
            {:error, :timeout}
          end)
        end

        expect_block_hash(36_438_663, @sepolia_parent)

        capture_log(fn -> send(self(), {:blocks, parse_sepolia_span(json_rpc_named_arguments)}) end)

        assert_received {:blocks, [36_438_664, 36_438_665, 36_438_666]}
      end

      # So is the read of the safe block
      test "waits for an L2 node that does not answer the read of the safe block", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        for _ <- 1..3 do
          expect_block_hash(36_438_663, "0x" <> String.duplicate("22", 32))

          expect(EthereumJSONRPC.Mox, :json_rpc, fn [%{method: "eth_getBlockByNumber", params: ["safe", false]}],
                                                    _options ->
            {:error, :timeout}
          end)
        end

        expect_block_hash(36_438_663, @sepolia_parent)

        capture_log(fn -> send(self(), {:blocks, parse_sepolia_span(json_rpc_named_arguments)}) end)

        assert_received {:blocks, [36_438_664, 36_438_665, 36_438_666]}
      end

      # The checks of a span batch also end with their time budget, `attempts` × `interval`, when the L2 node is slow
      test "stops checking a span batch when its time budget is spent", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        expect(EthereumJSONRPC.Mox, :json_rpc, fn [%{id: id, method: "eth_getBlockByNumber"}], _options ->
          Process.sleep(250)
          {:ok, [%{id: id, result: nil}]}
        end)

        log = capture_log(fn -> assert [] == parse_sepolia_span(json_rpc_named_arguments) end)

        assert log =~ "36438663"
      end

      test "maps a singular batch to the block after its parent", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        parent = :crypto.strong_rand_bytes(32)
        expect_block_numbers(%{parent => 41})

        assert [42] ==
                 [parent]
                 |> singular_batches_channel()
                 |> TransactionBatch.parse_frame_sequence(7, @l1_timestamp, {0, 2, 0}, json_rpc_named_arguments)
                 |> Enum.map(& &1.l2_block_number)
      end

      test "waits for the parent of a singular batch that the L2 node does not return yet", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        parent = :crypto.strong_rand_bytes(32)
        expect_block_numbers(%{parent => nil})
        expect_block_numbers(%{parent => 41})

        assert [42] ==
                 [parent]
                 |> singular_batches_channel()
                 |> TransactionBatch.parse_frame_sequence(7, @l1_timestamp, {0, 2, 0}, json_rpc_named_arguments)
                 |> Enum.map(& &1.l2_block_number)
      end

      # A singular batch whose parent never comes is left out alone, not with the whole channel
      test "leaves out a singular batch whose parent stays unavailable, and keeps the other batches", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        found = :crypto.strong_rand_bytes(32)
        missing = :crypto.strong_rand_bytes(32)
        expect_block_numbers(%{found => 41, missing => nil})
        expect_block_numbers(%{missing => nil})
        expect_block_numbers(%{missing => nil})

        log =
          capture_log(fn ->
            assert [42] ==
                     [found, missing]
                     |> singular_batches_channel()
                     |> TransactionBatch.parse_frame_sequence(7, @l1_timestamp, {0, 2, 0}, json_rpc_named_arguments)
                     |> Enum.map(& &1.l2_block_number)
          end)

        assert log =~ Base.encode16(missing, case: :lower)
      end

      test "waits for an L2 node that does not answer, without spending the checks of a singular batch", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        parent = :crypto.strong_rand_bytes(32)

        expect(EthereumJSONRPC.Mox, :json_rpc, 4, fn [%{method: "eth_getBlockByHash"}], _options ->
          {:error, :timeout}
        end)

        expect_block_numbers(%{parent => 41})

        capture_log(fn ->
          send(
            self(),
            {:blocks,
             [parent]
             |> singular_batches_channel()
             |> TransactionBatch.parse_frame_sequence(7, @l1_timestamp, {0, 2, 0}, json_rpc_named_arguments)}
          )
        end)

        assert_received {:blocks, [%{l2_block_number: 42}]}
      end

      # The L2 node can still have the parent on an unsafe chain that derivation replaces
      test "waits for the parent of a span batch that is not safe yet to match", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        unsafe_parent = "0x" <> String.duplicate("22", 32)
        expect_block_hash(36_438_663, unsafe_parent)
        expect_safe_block(36_438_600)
        expect_block_hash(36_438_663, unsafe_parent)
        expect_block_hash(36_438_663, @sepolia_parent)

        assert [36_438_664, 36_438_665, 36_438_666] == parse_sepolia_span(json_rpc_named_arguments)
      end

      # The wait is bounded: a parent that never comes (an invalid batch, or a genesis setting mapping it beyond the L2
      # head) does not keep the fetcher from its other work for good
      test "leaves out a span batch whose parent stays unavailable", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        expect(EthereumJSONRPC.Mox, :json_rpc, 3, fn [%{id: id, method: "eth_getBlockByNumber"}], _options ->
          {:ok, [%{id: id, result: nil}]}
        end)

        log = capture_log(fn -> assert [] == parse_sepolia_span(json_rpc_named_arguments) end)

        assert log =~ "36438663"
      end
    end

    # Parses a channel of the Mantle Sepolia span batch of L2 blocks 36438664..36438666 and returns the L2 block numbers
    defp parse_sepolia_span(json_rpc_named_arguments) do
      (1_774_422_001 - 1_702_194_288)
      |> span_batch_channel(@sepolia_parent, 3)
      |> TransactionBatch.parse_frame_sequence(7, @l1_timestamp, @sepolia_span_params, json_rpc_named_arguments)
      |> Enum.map(& &1.l2_block_number)
    end

    # The zlib-compressed channel of singular batches (version 0) after the given parents
    defp singular_batches_channel(parent_hashes) do
      parent_hashes
      |> Enum.map_join(fn parent_hash ->
        ExRLP.encode(<<0>> <> ExRLP.encode([parent_hash, <<1>>, <<0::256>>, <<2>>, []]))
      end)
      |> :zlib.compress()
    end

    # The blocks eth_getBlockByHash gives for the given parents (`nil` for a block the node does not return)
    defp expect_block_numbers(numbers_by_hashes) do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn requests, _options ->
        assert Enum.sort(Enum.map(requests, fn %{params: [hash, false]} -> hash.bytes end)) ==
                 Enum.sort(Map.keys(numbers_by_hashes))

        {:ok,
         Enum.map(requests, fn %{id: id, params: [hash, false]} ->
           result =
             case Map.fetch!(numbers_by_hashes, hash.bytes) do
               nil -> nil
               number -> %{"number" => number, "hash" => "0x" <> Base.encode16(hash.bytes, case: :lower)}
             end

           %{id: id, result: result}
         end)}
      end)
    end

    # The zlib-compressed channel of one span batch (see `span_batch/3`)
    defp span_batch_channel(rel_timestamp, parent_hash, block_count) do
      :zlib.compress(ExRLP.encode(span_batch(rel_timestamp, parent_hash, block_count)))
    end

    # A span batch: version 1, then `rel_timestamp`, the L1 origin number, the first 20 bytes of the parent hash
    # (`parent_check`), the L1 origin check and the block count. The rest of the span batch is not read.
    defp span_batch(rel_timestamp, "0x" <> parent_hash, block_count) do
      <<parent_check::binary-size(20), _::binary>> = Base.decode16!(parent_hash, case: :lower)

      <<1>> <>
        LEB128.encode(rel_timestamp) <>
        LEB128.encode(5_000_000) <> parent_check <> <<0::160>> <> LEB128.encode(block_count)
    end

    # The L2 safe block, as eth_getBlockByNumber gives it for the `safe` tag
    defp expect_safe_block(number) do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn [%{id: id, method: "eth_getBlockByNumber", params: ["safe", false]}],
                                                _options ->
        {:ok, [%{id: id, result: full_block(number)}]}
      end)
    end

    defp full_block(number) do
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
        "number" => EthereumJSONRPC.integer_to_quantity(number),
        "parentHash" => zero_hash,
        "receiptsRoot" => zero_hash,
        "sha3Uncles" => zero_hash,
        "size" => "0x200",
        "stateRoot" => zero_hash,
        "timestamp" => "0x6846a3a0",
        "totalDifficulty" => "0x0",
        "transactions" => [],
        "transactionsRoot" => zero_hash,
        "uncles" => []
      }
    end

    # The hash eth_getBlockByNumber gives for the L2 block `number`
    defp expect_block_hash(number, hash) do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn [%{id: id, method: "eth_getBlockByNumber", params: [quantity, false]}],
                                                _options ->
        assert EthereumJSONRPC.quantity_to_integer(quantity) == number
        {:ok, [%{id: id, result: %{"number" => EthereumJSONRPC.integer_to_quantity(number), "hash" => hash}}]}
      end)
    end
  end
end
