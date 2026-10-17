defmodule Indexer.Transform.Optimism.WithdrawalsTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use ExUnit.Case, async: false

    import Explorer.OptimismBridgeFixtures

    alias Indexer.Transform.Optimism.Withdrawals

    @message_passer "0x4200000000000000000000000000000000000016"

    setup do
      configure_bridges()
      previous = Application.get_env(:indexer, Indexer.Fetcher.Optimism.Withdrawal)

      Application.put_env(:indexer, Indexer.Fetcher.Optimism.Withdrawal,
        start_block_l2: "1",
        message_passer: @message_passer
      )

      on_exit(fn -> Application.put_env(:indexer, Indexer.Fetcher.Optimism.Withdrawal, previous) end)
    end

    test "decodes each MessagePassed log of a transaction on its own (LD1)" do
      transaction = withdrawal(:eth)

      logs =
        for name <- [:eth, :erc20] do
          %{"topics" => [event, nonce, sender, target], "data" => data} = withdrawal(name)["message_passed"]

          %{
            address_hash: @message_passer,
            first_topic: event,
            second_topic: nonce,
            third_topic: sender,
            fourth_topic: target,
            data: data,
            transaction_hash: transaction["l2_transaction_hash"],
            block_number: transaction["l2_block_number"]
          }
        end

      assert [eth, erc20] = Withdrawals.parse(logs)
      assert Map.take(eth, Map.keys(expected_transfer(withdrawal(:eth)))) == expected_transfer(withdrawal(:eth))
      assert Map.take(erc20, Map.keys(expected_transfer(withdrawal(:erc20)))) == expected_transfer(withdrawal(:erc20))
    end
  end
end
