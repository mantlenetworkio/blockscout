if Application.get_env(:explorer, :chain_type) == :optimism do
  defmodule Indexer.Fetcher.Optimism.WithdrawalCatchupTest do
    use EthereumJSONRPC.Case, async: false
    use Explorer.DataCase

    import EthereumJSONRPC, only: [quantity_to_integer: 1]
    import Mox

    alias Explorer.Chain.Optimism.Withdrawal, as: OptimismWithdrawal
    alias Explorer.Repo
    alias Indexer.Fetcher.Optimism
    alias Indexer.Fetcher.Optimism.Withdrawal

    @message_passer "0x4200000000000000000000000000000000000016"
    @counter_type "optimism_withdrawals_fetcher_last_l2_block_hash"

    setup :verify_on_exit!

    setup %{json_rpc_named_arguments: json_rpc_named_arguments} do
      %{json_rpc_named_arguments: Keyword.put(json_rpc_named_arguments, :transport, EthereumJSONRPC.Mox)}
    end

    defp block_hash(number), do: "0x" <> String.pad_leading(Integer.to_string(number, 16), 64, "0")

    describe "handle_info(:continue, state)" do
      # The realtime fetcher imports the withdrawals of new blocks while the catchup scans the history, so on a database
      # without a stored catchup position the newest withdrawal can sit above the end of the range being caught up.
      # Mantle's L2 nodes reject a reversed eth_getLogs range (-32602 "invalid block range params").
      test "a realtime withdrawal above the caught-up range sends no reversed eth_getLogs range", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        realtime_transaction = insert(:transaction)

        Repo.insert!(%OptimismWithdrawal{
          msg_nonce: Decimal.new(7),
          hash: transaction_hash(),
          l2_transaction_hash: realtime_transaction.hash,
          l2_block_number: 500
        })

        stub(EthereumJSONRPC.Mox, :json_rpc, fn
          %{method: "eth_getLogs", params: [%{fromBlock: from_block, toBlock: to_block}]}, _options ->
            assert quantity_to_integer(from_block) <= quantity_to_integer(to_block),
                   "eth_getLogs range #{from_block}..#{to_block} is reversed"

            {:ok, []}

          %{method: "eth_getTransactionByHash", params: [hash]}, _options ->
            {:ok, %{"hash" => hash}}

          [%{id: id, method: "eth_getBlockByNumber", params: [number, false]}], _options ->
            {:ok, [%{id: id, result: %{"number" => number, "hash" => block_hash(quantity_to_integer(number))}}]}
        end)

        state = %{
          start_block_l2: 1,
          start_block: 1,
          safe_block: 100,
          safe_block_is_latest: true,
          message_passer: @message_passer,
          json_rpc_named_arguments: json_rpc_named_arguments,
          eth_get_logs_range_size: 1000
        }

        assert {:stop, :normal, _state} = Withdrawal.handle_info(:continue, state)

        # the catchup finished the range and stored its end, so the next start resumes from there
        assert String.downcase(Optimism.get_last_block_hash(@counter_type)) == block_hash(100)
      end
    end
  end
end
