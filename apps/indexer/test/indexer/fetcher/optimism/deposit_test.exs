defmodule Indexer.Fetcher.Optimism.DepositTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use ExUnit.Case, async: false

    import Explorer.OptimismBridgeFixtures

    alias Explorer.Chain.Optimism.BridgeMessage
    alias Indexer.Fetcher.Optimism.Deposit

    describe "event_to_deposit/5" do
      for name <- [:eth, :mnt, :erc20, :message] do
        test "derives the L2 transaction of the Sepolia #{name} deposit and decodes its transfer" do
          configure_bridges()
          fixture = deposit(unquote(name))
          expected = expected_transfer(fixture)

          deposit = Deposit.event_to_deposit(fixture["l1_event"], %{}, %{}, 126, BridgeMessage.bridges())

          assert deposit.l2_transaction_hash == fixture["l2_transaction_hash"]
          assert Map.take(deposit, Map.keys(expected)) == expected
        end
      end

      test "leaves the transfer out when decoding is not configured" do
        configure_bridges()
        fixture = deposit(:eth)

        deposit = Deposit.event_to_deposit(fixture["l1_event"], %{}, %{}, 126, nil)

        assert deposit.l2_transaction_hash == fixture["l2_transaction_hash"]
        refute Map.has_key?(deposit, :transfer_type)
      end
    end
  end
end
