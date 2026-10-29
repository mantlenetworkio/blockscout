if Application.get_env(:explorer, :chain_type) == :optimism do
  defmodule Indexer.Fetcher.Optimism.LegacyBridgeTest do
    use EthereumJSONRPC.Case, async: false
    use Explorer.DataCase

    import ExUnit.CaptureLog
    import Explorer.OptimismLegacyBridgeFixtures
    import Mox

    alias Explorer.Application.Constants
    alias Explorer.Chain.Optimism.{BridgeMessage, LegacyBridgeTransfer, MessageRelay}
    alias Indexer.Fetcher.Optimism.LegacyBridge

    @l2_messenger "0x4200000000000000000000000000000000000007"
    @l1_messenger "0x37dac5312e31adb8bb0802fc72ca84da5cdfcb4c"
    @message_passer "0x4200000000000000000000000000000000000016"
    @sent "0xcb0f7ffd78f9aee47a248fae8db181db6eee833039123e026dcbff529522e52a"
    @relayed "0x4641df4a962071e12719d8c8c8e5ac7fc4d97b927346a3d7a335b1f7517e133c"
    @failed "0x99d0e048484baa1b1540b1367cb128acd7ab2946d1ed91ec10e3c85e4bf51b8f"
    @true_word "0x0000000000000000000000000000000000000000000000000000000000000001"
    @false_word "0x0000000000000000000000000000000000000000000000000000000000000000"

    setup :verify_on_exit!

    setup %{json_rpc_named_arguments: json_rpc_named_arguments} do
      configure_legacy_bridges("sepolia")
      %{json_rpc_named_arguments: Keyword.put(json_rpc_named_arguments, :transport, EthereumJSONRPC.Mox)}
    end

    describe "handle_continue/2" do
      test "reads the v1 L1 range through the L1 RPC and the v1 L2 range through the legacy L2 RPC" do
        optimism = Application.get_env(:indexer, Indexer.Fetcher.Optimism)
        legacy_bridge = Application.get_env(:indexer, LegacyBridge)

        on_exit(fn ->
          Application.put_env(:indexer, Indexer.Fetcher.Optimism, optimism)
          Application.put_env(:indexer, LegacyBridge, legacy_bridge)
        end)

        Application.put_env(
          :indexer,
          Indexer.Fetcher.Optimism,
          Keyword.put(optimism, :optimism_l1_rpc, "http://l1.example:8545")
        )

        Application.put_env(
          :indexer,
          LegacyBridge,
          Keyword.put(legacy_bridge || [], :l2_rpc, "http://legacy-l2.example:8545")
        )

        assert {:noreply, state} = LegacyBridge.handle_continue([transport: EthereumJSONRPC.Mox], %{})

        l1_transport_options = state.l1.json_rpc_named_arguments[:transport_options]
        assert l1_transport_options[:urls] == ["http://l1.example:8545"]
        # requests to the parent chain are counted by the L1 request metrics
        assert l1_transport_options[:http_options][:layer] == :l1

        l2_transport_options = state.l2.json_rpc_named_arguments[:transport_options]
        assert l2_transport_options[:urls] == ["http://legacy-l2.example:8545"]
        # the node of the v1 era is an L2 node, not the parent chain
        refute Keyword.has_key?(l2_transport_options[:http_options], :layer)
      end
    end

    describe "a full run" do
      test "writes the v1 rows and relays, and validates them against the chain", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        withdrawal = legacy_withdrawal(:mnt)
        deposit = legacy_deposit(:eth)
        # in call order: each side's logs, then the blocks of its v1 messages; the validation last
        expect_logs(@l2_messenger, "0x1", "0x2", [withdrawal["sent_message"], relay_log(deposit)])
        expect_blocks()
        expect_logs(@l1_messenger, "0xA", "0xB", [deposit["sent_message"]])
        expect_blocks()
        expect_sent_messages([@true_word])

        state = run(state(json_rpc_named_arguments))

        assert {:stop, :normal, _state} = state
        assert Constants.get_constant_value("optimism_legacy_bridge_validated") == "true"
        assert Constants.get_constant_value("optimism_legacy_bridge_l2_block") == "2"
        assert Constants.get_constant_value("optimism_legacy_bridge_l1_block") == "11"

        assert [stored_deposit, stored_withdrawal] = LegacyBridgeTransfer |> order_by(:direction) |> Repo.all()
        assert %{direction: :deposit, transfer_type: :eth} = stored_deposit
        assert_stored(stored_deposit, deposit)
        assert %{direction: :withdrawal, transfer_type: :mnt} = stored_withdrawal
        assert_stored(stored_withdrawal, withdrawal)

        assert to_string(stored_withdrawal.migrated_withdrawal_hash) ==
                 expected_legacy(withdrawal).migrated_withdrawal_hash

        assert [%{chain: :l2, event_type: :RelayedMessage}] = Repo.all(MessageRelay)
      end

      test "a migrated hash the chain does not know fails the validation", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        expect_one_message_each_side()
        expect_sent_messages([@false_word])

        log = capture_log(fn -> run(state(json_rpc_named_arguments)) end)

        assert Constants.get_constant_value("optimism_legacy_bridge_validated") == "false"
        assert log =~ "100000"
        assert Repo.aggregate(LegacyBridgeTransfer, :count) == 2
      end

      test "an RPC error is asked again and logged, never taken for an answer", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        expect_one_message_each_side()

        expect(EthereumJSONRPC.Mox, :json_rpc, fn [%{id: id, method: "eth_call"}], _options ->
          {:ok, [%{id: id, error: %{code: -32_005, message: "rate limited"}}]}
        end)

        expect_sent_messages([@true_word])

        log = capture_log(fn -> run(state(json_rpc_named_arguments)) end)

        assert Constants.get_constant_value("optimism_legacy_bridge_validated") == "true"
        assert log =~ "rate limited"
      end

      test "an answer that is not a word is asked again, not taken for an answer", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        expect_one_message_each_side()

        # what an eth_call to an address without code answers
        expect(EthereumJSONRPC.Mox, :json_rpc, fn [%{id: id, method: "eth_call"}], _options ->
          {:ok, [%{id: id, result: "0x"}]}
        end)

        expect_sent_messages([@true_word])

        log = capture_log(fn -> run(state(json_rpc_named_arguments)) end)

        assert Constants.get_constant_value("optimism_legacy_bridge_validated") == "true"
        assert log =~ ~s(result: "0x")
      end

      test "a legacy relay of no v1 message fails the validation, and its blocks are logged", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        stray = %{relay_log(legacy_deposit(:eth)) | "topics" => [@relayed, "0x" <> String.duplicate("ab", 32)]}
        expect_logs(@l2_messenger, "0x1", "0x2", [legacy_withdrawal(:mnt)["sent_message"], stray])
        expect_blocks()
        expect_logs(@l1_messenger, "0xA", "0xB", [legacy_deposit(:eth)["sent_message"]])
        expect_blocks()

        log = capture_log(fn -> run(state(json_rpc_named_arguments)) end)

        assert Constants.get_constant_value("optimism_legacy_bridge_validated") == "false"
        # a relay past the upgrade (a range ending too late) shows by its blocks
        assert log =~ "1 on L2 (blocks 1..1)"
      end

      test "an empty history fails the validation: the RPC may serve no pre-Bedrock logs", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        expect_logs(@l2_messenger, "0x1", "0x2", [])
        expect_logs(@l1_messenger, "0xA", "0xB", [])

        log = capture_log(fn -> run(state(json_rpc_named_arguments)) end)

        assert Constants.get_constant_value("optimism_legacy_bridge_validated") == "false"
        assert log =~ "no v1 withdrawal"
        assert log =~ "no v1 deposit"
      end

      test "withdrawal nonces with a gap, or deposit nonces not starting at 0, fail the validation", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        written_by_a_previous_run()
        insert_legacy(:withdrawal, :mnt)
        insert_legacy(:withdrawal, :erc20)
        insert_legacy(:deposit, :mnt)

        log = capture_log(fn -> run(state(json_rpc_named_arguments)) end)

        assert Constants.get_constant_value("optimism_legacy_bridge_validated") == "false"
        assert log =~ "100000..100005"
        assert log =~ "deposit nonces start at 1"
      end
    end

    describe "restarts" do
      test "a finished backfill does not run again" do
        Constants.set_constant_value("optimism_legacy_bridge_validated", "true")

        assert {:stop, :normal, %{}} = LegacyBridge.handle_continue([], %{})
      end

      test "resumes after the last block written", %{json_rpc_named_arguments: json_rpc_named_arguments} do
        written_by_a_previous_run()
        insert_legacy(:withdrawal, :mnt)
        deposit = insert_legacy(:deposit, :eth)
        insert(:op_message_relay, message_hash: deposit.message_hash, chain: :l2, block_number: 1)
        expect_sent_messages([@true_word])

        # no eth_getLogs: both ranges are already written
        log = capture_log(fn -> run(state(json_rpc_named_arguments)) end)

        assert Constants.get_constant_value("optimism_legacy_bridge_validated") == "true"
        refute log =~ "error"
      end
    end

    # Drives the phases the way the GenServer does: L2, then L1, then the validation
    defp run(state) do
      {:noreply, state} = LegacyBridge.handle_info(:continue, state)
      {:noreply, state} = LegacyBridge.handle_info(:continue, state)
      LegacyBridge.handle_info(:continue, state)
    end

    defp state(json_rpc_named_arguments) do
      bridges = BridgeMessage.bridges()

      %{
        phase: :l2,
        bridges: bridges,
        validation_json_rpc_named_arguments: json_rpc_named_arguments,
        l2: %{
          direction: :withdrawal,
          chain: :l2,
          messenger: bridges.l2_cross_domain_messenger,
          start_block: 1,
          end_block: 2,
          range_size: 250,
          progress_constant: "optimism_legacy_bridge_l2_block",
          json_rpc_named_arguments: json_rpc_named_arguments
        },
        l1: %{
          direction: :deposit,
          chain: :l1,
          messenger: bridges.l1_cross_domain_messenger,
          start_block: 10,
          end_block: 11,
          range_size: 250,
          progress_constant: "optimism_legacy_bridge_l1_block",
          json_rpc_named_arguments: json_rpc_named_arguments
        }
      }
    end

    # Both ranges written up to their ends, as a previous run leaves them
    defp written_by_a_previous_run do
      Constants.set_constant_value("optimism_legacy_bridge_l2_block", "2")
      Constants.set_constant_value("optimism_legacy_bridge_l1_block", "11")
    end

    # A v1 withdrawal on L2 and a v1 deposit on L1, each with the block request it causes
    defp expect_one_message_each_side do
      expect_logs(@l2_messenger, "0x1", "0x2", [legacy_withdrawal(:mnt)["sent_message"]])
      expect_blocks()
      expect_logs(@l1_messenger, "0xA", "0xB", [legacy_deposit(:eth)["sent_message"]])
      expect_blocks()
    end

    # The row holds the log's transaction, block, block time and nonce, and the decoded transfer
    defp assert_stored(row, %{"sent_message" => log} = fixture) do
      expected = expected_legacy(fixture)

      assert to_string(row.transaction_hash) == log["transactionHash"]
      assert row.block_number == String.to_integer(String.trim_leading(log["blockNumber"], "0x"), 16)
      assert DateTime.compare(row.timestamp, DateTime.from_unix!(0x6500000)) == :eq
      assert Decimal.equal?(row.nonce, legacy_nonce(fixture))
      assert row.transfer_type == expected.transfer_type
      assert (row.transfer_amount && Decimal.to_integer(row.transfer_amount)) == expected.transfer_amount

      for key <- ~w(message_hash transfer_from_address_hash transfer_to_address_hash l1_token_address_hash
                    l2_token_address_hash)a do
        assert (Map.fetch!(row, key) && to_string(Map.fetch!(row, key))) == expected[key]
      end
    end

    defp relay_log(%{"relay" => relay}) do
      %{
        "address" => @l2_messenger,
        "topics" => [@relayed, relay["message_hash"]],
        "data" => "0x",
        "transactionHash" => relay["transaction_hash"],
        "blockNumber" => "0x" <> Integer.to_string(relay["block_number"], 16),
        "logIndex" => "0x0"
      }
    end

    defp expect_logs(address, from_block, to_block, logs) do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn %{
                                                  method: "eth_getLogs",
                                                  params: [
                                                    %{
                                                      address: ^address,
                                                      topics: [[@sent, @relayed, @failed]],
                                                      fromBlock: ^from_block,
                                                      toBlock: ^to_block
                                                    }
                                                  ]
                                                },
                                                _options ->
        {:ok, logs}
      end)
    end

    # The batch of eth_getBlockByNumber a side with v1 messages sends after its logs
    defp expect_blocks do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn requests, _options when is_list(requests) ->
        {:ok,
         Enum.map(requests, fn %{id: id, method: "eth_getBlockByNumber", params: [number, false]} ->
           %{
             id: id,
             result: %{
               "number" => number,
               "timestamp" => "0x6500000",
               "hash" => "0x" <> String.duplicate("11", 32),
               "transactions" => []
             }
           }
         end)}
      end)
    end

    defp expect_sent_messages(words) do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn requests, _options when is_list(requests) ->
        {:ok,
         requests
         |> Enum.zip(words)
         |> Enum.map(fn {%{
                           id: id,
                           method: "eth_call",
                           params: [%{to: @message_passer, data: "0x82e3702d" <> _}, "latest"]
                         }, word} ->
           %{id: id, result: word}
         end)}
      end)
    end
  end
end
