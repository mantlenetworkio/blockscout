# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule BlockScoutWeb.API.V2.OptimismControllerTest do
  use BlockScoutWeb.ConnCase
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  import Ecto.Query, only: [from: 2]
  import Mox

  alias Explorer.Application.Constants
  alias Explorer.Chain.{Address, Data}
  alias Explorer.Chain.Optimism.{Deposit, LegacyBridgeTransfer, OutputRoot, Withdrawal}
  alias Explorer.Repo
  alias Explorer.TestHelper

  setup :set_mox_global

  describe "/optimism/deposits" do
    if @chain_type == :optimism do
      test "deposits with next_page_params", %{conn: conn} do
        deposits = insert_list(51, :op_deposit)

        request = get(conn, "/api/v2/optimism/deposits")
        assert response = json_response(request, 200)

        request_2nd_page = get(conn, "/api/v2/optimism/deposits", response["next_page_params"])
        assert response_2nd_page = json_response(request_2nd_page, 200)

        check_paginated_response(response, response_2nd_page, deposits)
      end

      test "deposits filtered by address_hash returns only matching", %{conn: conn} do
        target = insert(:address)
        match1 = insert(:op_deposit, l1_transaction_origin: target.hash)
        match2 = insert(:op_deposit, l1_transaction_origin: target.hash)
        _other1 = insert(:op_deposit)
        _other2 = insert(:op_deposit)

        request = get(conn, "/api/v2/optimism/deposits", %{"address_hash" => to_string(target.hash)})

        assert %{"items" => items, "next_page_params" => nil} = json_response(request, 200)

        returned_hashes =
          items
          |> Enum.map(& &1["l2_transaction_hash"])
          |> Enum.sort()

        expected_hashes =
          [match1, match2]
          |> Enum.map(&to_string(&1.l2_transaction_hash))
          |> Enum.sort()

        assert returned_hashes == expected_hashes
      end

      test "deposits with invalid address_hash returns 422", %{conn: conn} do
        request = get(conn, "/api/v2/optimism/deposits", %{"address_hash" => "not_an_addr"})

        assert json_response(request, 422)
      end

      # Regression: previously params["address_hash"] returned nil under
      # CastAndValidate (atom-keyed params), filter no-op'd, and an unrelated
      # but well-formed address still returned the full chain.
      test "deposits returns empty items for a well-formed address that is absent from DB", %{conn: conn} do
        insert(:op_deposit)
        insert(:op_deposit)
        unrelated = insert(:address)

        request = get(conn, "/api/v2/optimism/deposits", %{"address_hash" => to_string(unrelated.hash)})

        assert %{"items" => [], "next_page_params" => nil} = json_response(request, 200)
      end

      test "deposits carry the relay result and what a replay needs", %{conn: conn} do
        deposit = insert_op_deposit_with_message(calldata: op_relay_message_calldata())

        insert(:op_message_relay,
          message_hash: TestHelper.topic(op_relay_message_hash()),
          event_type: :FailedRelayedMessage,
          transaction_hash: deposit.l2_transaction_hash,
          chain: :l2
        )

        request = get(conn, "/api/v2/optimism/deposits")
        assert %{"items" => [item]} = json_response(request, 200)

        assert %{
                 "relay_status" => "Relay failed",
                 "relay_transaction_hash" => nil,
                 "msg_target_address_hash" => "0x4200000000000000000000000000000000000007"
               } = item

        assert item["message_hash"] == op_relay_message_hash()
        assert item["msg_data"] == op_relay_message_calldata()

        replay = Explorer.Factory.transaction_hash()

        insert(:op_message_relay,
          message_hash: TestHelper.topic(op_relay_message_hash()),
          event_type: :RelayedMessage,
          transaction_hash: replay,
          chain: :l2
        )

        request = get(conn, "/api/v2/optimism/deposits")

        assert %{"items" => [%{"relay_status" => "Relayed", "relay_transaction_hash" => relay}]} =
                 json_response(request, 200)

        assert relay == to_string(replay)
      end
    end
  end

  describe "/optimism/deposits/count" do
    if @chain_type == :optimism do
      test "deposits_count without filter returns total", %{conn: conn} do
        insert_list(3, :op_deposit)

        request = get(conn, "/api/v2/optimism/deposits/count")

        assert json_response(request, 200) == 3
      end

      test "deposits_count filtered by address_hash returns scoped count", %{conn: conn} do
        target = insert(:address)
        insert(:op_deposit, l1_transaction_origin: target.hash)
        insert(:op_deposit, l1_transaction_origin: target.hash)
        insert(:op_deposit)

        request = get(conn, "/api/v2/optimism/deposits/count", %{"address_hash" => to_string(target.hash)})

        assert json_response(request, 200) == 2
      end

      test "deposits_count with invalid address_hash returns 422", %{conn: conn} do
        request = get(conn, "/api/v2/optimism/deposits/count", %{"address_hash" => "not_an_addr"})

        assert json_response(request, 422)
      end

      # Regression: see deposits regression note above.
      test "deposits_count returns 0 for a well-formed address that is absent from DB", %{conn: conn} do
        insert(:op_deposit)
        insert(:op_deposit)
        unrelated = insert(:address)

        request = get(conn, "/api/v2/optimism/deposits/count", %{"address_hash" => to_string(unrelated.hash)})

        assert json_response(request, 200) == 0
      end
    end
  end

  describe "/optimism/bridge/deposits" do
    if @chain_type == :optimism do
      test "needs an address and a limit between 1 and 1000", %{conn: conn} do
        address = to_string(address_hash())

        assert json_response(get(conn, "/api/v2/optimism/bridge/deposits"), 422)

        for limit <- ["0", "1001"] do
          request = get(conn, "/api/v2/optimism/bridge/deposits", %{"address_hash" => address, "limit" => limit})
          assert json_response(request, 422)
        end
      end

      test "an item carries the bridge transfer with exact decimal amounts", %{conn: conn} do
        address = address_hash()

        deposit =
          insert(:op_deposit,
            transfer_type: :erc20,
            transfer_from_address_hash: address,
            transfer_to_address_hash: address_hash(),
            l1_token_address_hash: address_hash(),
            l2_token_address_hash: address_hash(),
            transfer_amount: Decimal.new("1234567890123456789012345"),
            mnt_value: Decimal.new(0),
            eth_value: Decimal.new(0)
          )

        request = get(conn, "/api/v2/optimism/bridge/deposits", %{"address_hash" => to_string(address)})
        assert %{"items" => [item], "next_page_params" => nil} = json_response(request, 200)

        assert Map.keys(item) |> Enum.sort() ==
                 Enum.sort(~w(l1_transaction_hash l1_block_number l1_block_timestamp l2_transaction_hash status
                              transfer_type from_address_hash to_address_hash l1_token_address_hash l2_token_address_hash
                              amount mnt_value eth_value message_hash relay_transaction_hash msg_data
                              msg_target_address_hash is_legacy))

        assert %{
                 "status" => "Relayed",
                 "transfer_type" => "erc20",
                 "amount" => "1234567890123456789012345",
                 "mnt_value" => "0",
                 "msg_data" => nil,
                 "is_legacy" => false
               } = item

        assert item["l2_transaction_hash"] == to_string(deposit.l2_transaction_hash)
        assert item["from_address_hash"] == to_string(address)
      end

      test "a relay-failed deposit carries its replay payload", %{conn: conn} do
        address = address_hash()
        message_hash = transaction_hash()

        deposit =
          insert(:op_deposit, transfer_type: :message, transfer_from_address_hash: address, message_hash: message_hash)

        insert(:op_message_relay, message_hash: message_hash, event_type: :FailedRelayedMessage, chain: :l2)

        request = get(conn, "/api/v2/optimism/bridge/deposits", %{"address_hash" => to_string(address)})
        assert %{"items" => [item]} = json_response(request, 200)

        assert %{"status" => "Relay failed", "msg_target_address_hash" => "0x4200000000000000000000000000000000000007"} =
                 item

        assert item["msg_data"] == to_string(deposit.l2_transaction.input)
      end

      test "rejects a paging key that is half given or out of range", %{conn: conn} do
        params = %{"address_hash" => to_string(address_hash())}
        l2_transaction_hash = to_string(transaction_hash())

        for paging <- [
              %{"l1_block_number" => "20"},
              %{"l2_transaction_hash" => l2_transaction_hash},
              %{"l1_block_number" => "9223372036854775808", "l2_transaction_hash" => l2_transaction_hash}
            ] do
          request = get(conn, "/api/v2/optimism/bridge/deposits", Map.merge(params, paging))
          assert json_response(request, 422)
        end
      end

      test "pages with next_page_params and finds a transaction's deposits", %{conn: conn} do
        address = address_hash()

        deposits =
          for block_number <- [30, 20, 10] do
            insert(:op_deposit, transfer_type: :eth, transfer_from_address_hash: address, l1_block_number: block_number)
          end

        request = get(conn, "/api/v2/optimism/bridge/deposits", %{"address_hash" => to_string(address), "limit" => "2"})
        assert %{"items" => first_page, "next_page_params" => next_page_params} = json_response(request, 200)
        assert length(first_page) == 2

        assert %{"address_hash" => _, "limit" => 2, "l1_block_number" => 20, "l2_transaction_hash" => _} =
                 next_page_params

        request = get(conn, "/api/v2/optimism/bridge/deposits", next_page_params)
        assert %{"items" => [last], "next_page_params" => nil} = json_response(request, 200)
        assert last["l2_transaction_hash"] == to_string(List.last(deposits).l2_transaction_hash)

        filtered =
          get(conn, "/api/v2/optimism/bridge/deposits", %{
            "address_hash" => to_string(address),
            "transaction_hash" => to_string(hd(deposits).l1_transaction_hash)
          })

        assert %{"items" => [only]} = json_response(filtered, 200)
        assert only["l2_transaction_hash"] == to_string(hd(deposits).l2_transaction_hash)
      end
    end
  end

  describe "/optimism/bridge/withdrawals" do
    if @chain_type == :optimism do
      setup do
        Explorer.OptimismBridgeFixtures.configure_bridges()
        :ok
      end

      test "an item carries the bridge transfer, its status and the replay payload of a failed relay", %{conn: conn} do
        address = address_hash()
        withdrawal = insert_bridge_withdrawal(:eth, address)
        insert(:op_message_relay, message_hash: withdrawal.message_hash, event_type: :FailedRelayedMessage, chain: :l1)

        request = get(conn, "/api/v2/optimism/bridge/withdrawals", %{"address_hash" => to_string(address)})
        assert %{"items" => [item], "next_page_params" => nil} = json_response(request, 200)

        assert Map.keys(item) |> Enum.sort() ==
                 Enum.sort(
                   ~w(l2_transaction_hash l2_block_number l2_timestamp msg_nonce_raw status challenge_period_end
                              prove_transaction_hash l1_transaction_hash relay_transaction_hash transfer_type
                              from_address_hash to_address_hash l1_token_address_hash l2_token_address_hash amount
                              mnt_value eth_value message_hash msg_data msg_target_address_hash msg_gas_limit is_legacy)
                 )

        assert %{
                 "status" => "Relay failed",
                 "transfer_type" => "eth",
                 "amount" => "100000000000000",
                 "msg_target_address_hash" => "0x37dac5312e31adb8bb0802fc72ca84da5cdfcb4c",
                 "is_legacy" => false
               } = item

        assert item["msg_nonce_raw"] == Decimal.to_string(withdrawal.msg_nonce, :normal)
        assert "0xff8daf15" <> _ = item["msg_data"]
        assert is_binary(item["msg_gas_limit"])
      end

      test "pages by nonce and finds a transaction's withdrawals", %{conn: conn} do
        address = address_hash()
        withdrawals = Enum.map([:eth, :mnt, :erc20], &insert_bridge_withdrawal(&1, address))

        request =
          get(conn, "/api/v2/optimism/bridge/withdrawals", %{"address_hash" => to_string(address), "limit" => "2"})

        assert %{"items" => [_, _], "next_page_params" => %{"nonce" => _} = next_page_params} =
                 json_response(request, 200)

        request = get(conn, "/api/v2/optimism/bridge/withdrawals", next_page_params)
        assert %{"items" => [last], "next_page_params" => nil} = json_response(request, 200)
        lowest = Enum.min_by(withdrawals, & &1.msg_nonce, Decimal)
        assert last["msg_nonce_raw"] == Decimal.to_string(lowest.msg_nonce, :normal)

        filtered =
          get(conn, "/api/v2/optimism/bridge/withdrawals", %{
            "address_hash" => to_string(address),
            "transaction_hash" => to_string(lowest.l2_transaction_hash)
          })

        assert %{"items" => [only]} = json_response(filtered, 200)
        assert only["msg_nonce_raw"] == last["msg_nonce_raw"]
      end
    end
  end

  describe "/optimism/bridge v1 items" do
    if @chain_type == :optimism do
      setup do
        Explorer.OptimismLegacyBridgeFixtures.configure_legacy_bridges("sepolia")
        Constants.set_constant_value(LegacyBridgeTransfer.validated_constant(), "true")
        :ok
      end

      test "a v1 deposit is marked legacy, has no L2 transaction before its relay, and pages by its v0 hash", %{
        conn: conn
      } do
        address = address_hash()

        newer =
          Explorer.OptimismLegacyBridgeFixtures.insert_legacy(:deposit, :mnt, %{transfer_from_address_hash: address})

        older =
          Explorer.OptimismLegacyBridgeFixtures.insert_legacy(:deposit, :eth, %{transfer_from_address_hash: address})

        relay = insert(:op_message_relay, message_hash: newer.message_hash, event_type: :RelayedMessage, chain: :l2)

        request = get(conn, "/api/v2/optimism/bridge/deposits", %{"address_hash" => to_string(address), "limit" => "1"})
        assert %{"items" => [item], "next_page_params" => next_page_params} = json_response(request, 200)

        assert %{"is_legacy" => true, "status" => "Relayed", "transfer_type" => "mnt", "msg_data" => nil} = item
        assert item["l2_transaction_hash"] == to_string(relay.transaction_hash)

        # the tie of a v1 deposit is its v0 message hash, not the relay transaction
        assert %{"l1_block_number" => block_number, "l2_transaction_hash" => tie} = next_page_params
        assert {block_number, tie} == {newer.block_number, to_string(newer.message_hash)}

        request = get(conn, "/api/v2/optimism/bridge/deposits", next_page_params)
        assert %{"items" => [last], "next_page_params" => nil} = json_response(request, 200)

        assert %{"is_legacy" => true, "status" => "Pending", "l2_transaction_hash" => nil} = last
        assert last["l1_transaction_hash"] == to_string(older.transaction_hash)
      end

      test "a relay-failed v1 withdrawal is marked legacy and carries its migrated replay payload", %{conn: conn} do
        address = address_hash()

        withdrawal =
          Explorer.OptimismLegacyBridgeFixtures.insert_legacy(:withdrawal, :eth, %{transfer_from_address_hash: address})

        insert(:op_message_relay,
          message_hash: withdrawal.migrated_message_hash,
          event_type: :FailedRelayedMessage,
          chain: :l1
        )

        request = get(conn, "/api/v2/optimism/bridge/withdrawals", %{"address_hash" => to_string(address)})
        assert %{"items" => [item], "next_page_params" => nil} = json_response(request, 200)

        assert %{
                 "is_legacy" => true,
                 "status" => "Relay failed",
                 "transfer_type" => "eth",
                 "msg_target_address_hash" => "0x37dac5312e31adb8bb0802fc72ca84da5cdfcb4c"
               } = item

        assert item["msg_nonce_raw"] == Decimal.to_string(withdrawal.nonce, :normal)
        assert item["message_hash"] == to_string(withdrawal.migrated_message_hash)
        assert item["msg_data"] == to_string(withdrawal.migrated_msg_data)
        assert item["msg_gas_limit"] == Decimal.to_string(withdrawal.migrated_gas_limit, :normal)
      end
    end
  end

  describe "/optimism/withdrawals" do
    if @chain_type == :optimism do
      test "withdrawals filtered by address_hash returns only matching", %{conn: conn} do
        target = insert(:address)
        match = insert_withdrawal(from_address: target)
        _other = insert_withdrawal()
        _other2 = insert_withdrawal()

        request = get(conn, "/api/v2/optimism/withdrawals", %{"address_hash" => to_string(target.hash)})

        assert %{"items" => [item], "next_page_params" => nil} = json_response(request, 200)
        assert item["l2_transaction_hash"] == to_string(match.l2_transaction_hash)
      end

      test "withdrawals with invalid address_hash returns 422", %{conn: conn} do
        request = get(conn, "/api/v2/optimism/withdrawals", %{"address_hash" => "not_an_addr"})

        assert json_response(request, 422)
      end

      # Regression: see deposits regression note above.
      test "withdrawals returns empty items for a well-formed address that is absent from DB", %{conn: conn} do
        insert_withdrawal()
        insert_withdrawal()
        unrelated = insert(:address)

        request = get(conn, "/api/v2/optimism/withdrawals", %{"address_hash" => to_string(unrelated.hash)})

        assert %{"items" => [], "next_page_params" => nil} = json_response(request, 200)
      end

      test "reports a failed relay, and then the replay that delivered the message", %{conn: conn} do
        finalize = Explorer.Factory.transaction_hash()
        insert_op_withdrawal_with_message(calldata: op_relay_message_calldata(), finalized_in: finalize)

        insert(:op_message_relay,
          message_hash: TestHelper.topic(op_relay_message_hash()),
          event_type: :FailedRelayedMessage,
          transaction_hash: finalize,
          chain: :l1,
          block_number: 10
        )

        request = get(conn, "/api/v2/optimism/withdrawals")
        assert %{"items" => [item]} = json_response(request, 200)

        assert %{"status" => "Relay failed", "relay_transaction_hash" => nil, "message_hash" => message_hash} = item
        assert message_hash == op_relay_message_hash()
        assert item["l1_transaction_hash"] == to_string(finalize)

        replay = Explorer.Factory.transaction_hash()

        insert(:op_message_relay,
          message_hash: TestHelper.topic(op_relay_message_hash()),
          event_type: :RelayedMessage,
          transaction_hash: replay,
          chain: :l1,
          block_number: 20
        )

        request = get(conn, "/api/v2/optimism/withdrawals")

        assert %{"items" => [%{"status" => "Relayed", "relay_transaction_hash" => relay}]} =
                 json_response(request, 200)

        assert relay == to_string(replay)
      end

      test "a normal finalize relays in the finalize transaction", %{conn: conn} do
        finalize = Explorer.Factory.transaction_hash()
        insert_op_withdrawal_with_message(calldata: op_relay_message_calldata(), finalized_in: finalize)

        insert(:op_message_relay,
          message_hash: TestHelper.topic(op_relay_message_hash()),
          event_type: :RelayedMessage,
          transaction_hash: finalize,
          chain: :l1
        )

        request = get(conn, "/api/v2/optimism/withdrawals")
        assert %{"items" => [item]} = json_response(request, 200)
        assert item["status"] == "Relayed"
        assert item["relay_transaction_hash"] == item["l1_transaction_hash"]
      end

      test "a finalized withdrawal without an indexed relay stays Relayed", %{conn: conn} do
        insert_op_withdrawal_with_message(
          calldata: op_relay_message_calldata(),
          finalized_in: Explorer.Factory.transaction_hash()
        )

        request = get(conn, "/api/v2/optimism/withdrawals")

        assert %{"items" => [%{"status" => "Relayed", "relay_transaction_hash" => nil, "message_hash" => message_hash}]} =
                 json_response(request, 200)

        assert message_hash == op_relay_message_hash()
      end
    end
  end

  describe "/optimism/withdrawals/count" do
    if @chain_type == :optimism do
      test "withdrawals_count filtered by address_hash returns scoped count", %{conn: conn} do
        target = insert(:address)
        insert_withdrawal(from_address: target)
        insert_withdrawal(from_address: target)
        insert_withdrawal()

        request = get(conn, "/api/v2/optimism/withdrawals/count", %{"address_hash" => to_string(target.hash)})

        assert json_response(request, 200) == 2
      end

      test "withdrawals_count with invalid address_hash returns 422", %{conn: conn} do
        request = get(conn, "/api/v2/optimism/withdrawals/count", %{"address_hash" => "not_an_addr"})

        assert json_response(request, 422)
      end

      # Regression: see deposits regression note above.
      test "withdrawals_count returns 0 for a well-formed address that is absent from DB", %{conn: conn} do
        insert_withdrawal()
        insert_withdrawal()
        unrelated = insert(:address)

        request = get(conn, "/api/v2/optimism/withdrawals/count", %{"address_hash" => to_string(unrelated.hash)})

        assert json_response(request, 200) == 0
      end
    end
  end

  describe "/optimism/interop/messages" do
    if @chain_type == :optimism do
      test "handles message with 0x prefixed payload", %{conn: conn} do
        insert(:op_interop_message,
          payload: %Data{
            bytes: <<48, 120, 120, 73, 33, 116, 36, 121, 34, 115, 113, 39, 119, 112, 117, 118, 105, 106, 108, 93>>
          }
        )

        insert(:op_interop_message, payload: "0x30787849217424792273712777707576696a6c5d")

        TestHelper.get_chain_id_mock()

        conn = get(conn, "/api/v2/optimism/interop/messages")

        assert %{
                 "items" => [
                   %{
                     "payload" => "0x30787849217424792273712777707576696a6c5d"
                   },
                   %{
                     "payload" => "0x30787849217424792273712777707576696a6c5d"
                   }
                 ],
                 "next_page_params" => nil
               } = json_response(conn, 200)
      end
    end
  end

  describe "/optimism/output-roots/:index" do
    if @chain_type == :optimism do
      test "returns the root with its block range, counts, L1 finality and challenge period end", %{conn: conn} do
        Constants.set_constant_value(OutputRoot.finalization_period_constant(), "43200")
        insert(:op_output_root, l2_output_index: 7, l2_block_number: 3_000_100)

        root =
          insert(:op_output_root,
            l2_output_index: 8,
            l2_block_number: 3_000_110,
            l1_block_number: 500,
            l1_timestamp: ~U[2026-10-01 01:00:11.000000Z]
          )

        blocks = for n <- 3_000_101..3_000_110, do: insert(:block, number: n)
        :transaction |> insert() |> with_block(List.first(blocks))
        :transaction |> insert() |> with_block(List.last(blocks))
        :transaction |> insert() |> with_block(insert(:block, number: 3_000_111))
        Constants.set_constant_value(OutputRoot.l1_safe_block_number_constant(), "600")
        Constants.set_constant_value(OutputRoot.l1_finalized_block_number_constant(), "499")

        request = get(conn, "/api/v2/optimism/output-roots/8")

        assert %{
                 "l2_output_index" => 8,
                 "l2_block_number" => 3_000_110,
                 "l1_block_number" => 500,
                 "l1_timestamp" => "2026-10-01T01:00:11.000000Z",
                 "l2_start_block_number" => 3_000_101,
                 "l2_end_block_number" => 3_000_110,
                 "blocks_count" => 10,
                 "transactions_count" => 2,
                 "l1_finality" => "safe",
                 "challenge_period_end" => "2026-10-01T13:00:11.000000Z",
                 "output_root" => output_root,
                 "l1_transaction_hash" => l1_transaction_hash
               } = json_response(request, 200)

        assert output_root == to_string(root.output_root)
        assert l1_transaction_hash == to_string(root.l1_transaction_hash)
      end

      test "reports an unknown range when the previous root is missing", %{conn: conn} do
        insert(:op_output_root, l2_output_index: 12, l2_block_number: 3_000_300)

        request = get(conn, "/api/v2/optimism/output-roots/12")

        assert %{
                 "l2_start_block_number" => nil,
                 "l2_end_block_number" => 3_000_300,
                 "blocks_count" => nil,
                 "transactions_count" => nil,
                 "l1_finality" => nil,
                 "challenge_period_end" => nil
               } = json_response(request, 200)
      end

      test "returns 404 for an unknown index", %{conn: conn} do
        request = get(conn, "/api/v2/optimism/output-roots/999")
        assert json_response(request, 404)
      end

      test "returns 422 for a non-integer index", %{conn: conn} do
        request = get(conn, "/api/v2/optimism/output-roots/abc")
        assert json_response(request, 422)
      end

      # The counter may serve a table estimate, so only the routing is asserted: "count" must not reach /:index.
      test "keeps /output-roots/count routed to the counter", %{conn: conn} do
        request = get(conn, "/api/v2/optimism/output-roots/count")
        assert is_integer(json_response(request, 200))
      end
    end
  end

  defp check_paginated_response(first_page_resp, second_page_resp, items) do
    assert Enum.count(first_page_resp["items"]) == 50
    assert first_page_resp["next_page_params"] != nil
    compare_item(Enum.at(items, 50), Enum.at(first_page_resp["items"], 0))
    compare_item(Enum.at(items, 1), Enum.at(first_page_resp["items"], 49))

    assert Enum.count(second_page_resp["items"]) == 1
    assert second_page_resp["next_page_params"] == nil
    compare_item(Enum.at(items, 0), Enum.at(second_page_resp["items"], 0))
  end

  defp compare_item(%Deposit{} = deposit, json) do
    assert deposit.l1_block_number == json["l1_block_number"]
    assert DateTime.to_iso8601(deposit.l1_block_timestamp) == json["l1_block_timestamp"]
    assert to_string(deposit.l1_transaction_hash) == json["l1_transaction_hash"]
    assert Address.checksum(deposit.l1_transaction_origin) == Address.checksum(json["l1_transaction_origin"])
    assert to_string(deposit.l2_transaction.hash) == json["l2_transaction_hash"]
    assert to_string(deposit.l2_transaction.gas) == json["l2_transaction_gas_limit"]
  end

  # A withdrawal with the MessagePassed log of a fixture, decoded as if by the indexer, sent by `address`
  defp insert_bridge_withdrawal(fixture_name, address) do
    fixture = Explorer.OptimismBridgeFixtures.withdrawal(fixture_name)
    expected = Explorer.OptimismBridgeFixtures.expected_transfer(fixture)
    row = insert_op_withdrawal_with_message(message_passed: fixture["message_passed"])

    {1, [withdrawal]} =
      Repo.update_all(
        from(w in Withdrawal, where: w.msg_nonce == ^row.msg_nonce, select: w),
        set: [
          message_hash: TestHelper.topic(expected.message_hash),
          transfer_type: expected.transfer_type,
          transfer_from_address_hash: address,
          transfer_to_address_hash: address_hash(),
          transfer_amount: expected.transfer_amount && Decimal.new(expected.transfer_amount),
          mnt_value: Decimal.new(expected.mnt_value),
          eth_value: Decimal.new(expected.eth_value)
        ]
      )

    withdrawal
  end

  defp insert_withdrawal(opts \\ []) do
    transaction = insert(:transaction, Keyword.take(opts, [:from_address]))

    Repo.insert!(%Withdrawal{
      msg_nonce: Decimal.new(System.unique_integer([:positive])),
      hash: Explorer.Factory.transaction_hash(),
      l2_transaction_hash: transaction.hash,
      l2_block_number: transaction.block_number || 1
    })
  end
end
