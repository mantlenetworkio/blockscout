defmodule Indexer.Fetcher.Optimism.WithdrawalTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use ExUnit.Case, async: false

    import Explorer.OptimismBridgeFixtures

    alias Explorer.Chain.Optimism.BridgeMessage
    alias Indexer.Fetcher.Optimism.Withdrawal

    describe "event_to_withdrawal/7" do
      for name <- [:eth, :mnt, :erc20, :message] do
        test "decodes the transfer of the Sepolia #{name} withdrawal" do
          configure_bridges()
          fixture = withdrawal(unquote(name))
          expected = expected_transfer(fixture)
          %{"topics" => [_, "0x" <> nonce = nonce_topic, sender, target], "data" => data} = fixture["message_passed"]

          withdrawal =
            Withdrawal.event_to_withdrawal(
              nonce_topic,
              sender,
              target,
              data,
              fixture["l2_transaction_hash"],
              fixture["l2_block_number"],
              BridgeMessage.bridges()
            )

          assert withdrawal.msg_nonce == Decimal.new(String.to_integer(nonce, 16))
          assert withdrawal.l2_block_number == fixture["l2_block_number"]
          assert Map.take(withdrawal, Map.keys(expected)) == expected
        end
      end

      test "leaves the transfer out when decoding is not configured" do
        configure_bridges()
        %{"topics" => [_, nonce, sender, target], "data" => data} = withdrawal(:eth)["message_passed"]

        withdrawal =
          Withdrawal.event_to_withdrawal(nonce, sender, target, data, withdrawal(:eth)["l2_transaction_hash"], 1, nil)

        refute Map.has_key?(withdrawal, :transfer_type)
      end
    end
  end
end
