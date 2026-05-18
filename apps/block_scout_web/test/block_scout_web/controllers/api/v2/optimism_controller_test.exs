defmodule BlockScoutWeb.API.V2.OptimismControllerTest do
  use BlockScoutWeb.ConnCase
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  import Mox

  alias Explorer.Chain.{Address, Data}
  alias Explorer.Chain.Optimism.{Deposit, Withdrawal}
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
