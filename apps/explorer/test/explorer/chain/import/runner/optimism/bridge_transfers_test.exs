defmodule Explorer.Chain.Import.Runner.Optimism.BridgeTransfersTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use Explorer.DataCase, async: false

    import Explorer.OptimismBridgeFixtures, only: [stored_transfer: 1]

    alias Explorer.Chain
    alias Explorer.Chain.Optimism.{Deposit, Withdrawal}

    # the amount is above 2^64, so that a precision loss would show
    @transfer %{
      message_hash: "0xfb298b633cf63d79bd8bde7288d5cbe099873cb6781d446e512ed64049159d1d",
      transfer_type: :erc20,
      transfer_from_address_hash: "0xf6c137e1b34ce01709639f143c8166dfa26f57a5",
      transfer_to_address_hash: "0x00c6db7eaecb00c4c3c69e7851114b8a3663cbe8",
      l1_token_address_hash: "0x6acb0d92852b7e98121a6a5a1c2773f90020cb57",
      l2_token_address_hash: "0xc62c9b7be5d4e5d415f682b2331bfa5f0c8d061a",
      transfer_amount: 123_456_789_012_345_678_901_234_567_890,
      mnt_value: 0,
      eth_value: 7
    }

    describe "optimism_deposits" do
      test "stores the bridge transfer of a deposit" do
        params = Map.merge(deposit_params(), @transfer)

        import_deposits([params])

        assert stored(Deposit, params.l2_transaction_hash) == @transfer
      end

      test "a re-import without a transfer keeps the stored one" do
        params = deposit_params()

        import_deposits([Map.merge(params, @transfer)])
        import_deposits([params])

        assert stored(Deposit, params.l2_transaction_hash) == @transfer
      end

      test "a re-import with a transfer fills a deposit stored without one" do
        params = deposit_params()

        import_deposits([params])
        import_deposits([Map.merge(params, @transfer)])

        assert stored(Deposit, params.l2_transaction_hash) == @transfer
      end
    end

    describe "optimism_withdrawals" do
      test "stores the bridge transfer of a withdrawal" do
        params = Map.merge(withdrawal_params(), @transfer)

        import_withdrawals([params])

        assert stored(Withdrawal, params.msg_nonce) == @transfer
      end

      test "a re-import without a transfer keeps the stored one" do
        params = withdrawal_params()

        import_withdrawals([Map.merge(params, @transfer)])
        import_withdrawals([params])

        assert stored(Withdrawal, params.msg_nonce) == @transfer
      end

      test "a re-import of the nonce for another withdrawal does not keep the old transfer" do
        params = withdrawal_params()

        import_withdrawals([Map.merge(params, @transfer)])
        import_withdrawals([%{params | hash: to_string(transaction_hash())}])

        assert stored(Withdrawal, params.msg_nonce) == Map.new(@transfer, fn {key, _} -> {key, nil} end)
      end

      test "a re-import with a transfer fills a withdrawal stored without one" do
        params = withdrawal_params()

        import_withdrawals([params])
        import_withdrawals([Map.merge(params, @transfer)])

        assert stored(Withdrawal, params.msg_nonce) == @transfer
      end
    end

    defp deposit_params do
      %{
        l1_block_number: 100,
        l1_block_timestamp: ~U[2026-10-16 00:00:00.000000Z],
        l1_transaction_hash: to_string(transaction_hash()),
        l1_transaction_origin: to_string(address_hash()),
        l2_transaction_hash: to_string(transaction_hash())
      }
    end

    defp withdrawal_params do
      %{
        msg_nonce: Decimal.new(System.unique_integer([:positive])),
        hash: to_string(transaction_hash()),
        l2_transaction_hash: to_string(transaction_hash()),
        l2_block_number: 100
      }
    end

    defp import_deposits(params), do: {:ok, _} = Chain.import(%{optimism_deposits: %{params: params}})

    defp import_withdrawals(params), do: {:ok, _} = Chain.import(%{optimism_withdrawals: %{params: params}})

    defp stored(schema, key), do: stored_transfer(Repo.get!(schema, key))
  end
end
