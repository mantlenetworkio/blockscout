defmodule Explorer.Chain.Optimism.LegacyBridgeTransferTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use Explorer.DataCase, async: false

    alias Explorer.Chain.Optimism.LegacyBridgeTransfer

    describe "upsert_all/1" do
      test "stores v1 deposits and withdrawals keyed by direction and nonce" do
        assert LegacyBridgeTransfer.upsert_all([row(:deposit, 7, 100), row(:withdrawal, 7, 200)]) == 2

        assert [%{direction: :deposit, transfer_amount: deposit_amount}, %{direction: :withdrawal}] =
                 LegacyBridgeTransfer |> order_by(:direction) |> Repo.all()

        assert Decimal.equal?(deposit_amount, 100)
      end

      test "replaces a row on a second run, so the backfill can repeat a range" do
        LegacyBridgeTransfer.upsert_all([row(:deposit, 7, 100)])
        LegacyBridgeTransfer.upsert_all([row(:deposit, 7, 300)])

        assert [%{transfer_amount: amount}] = Repo.all(LegacyBridgeTransfer)
        assert Decimal.equal?(amount, 300)
      end

      test "raises on a value its column cannot take, instead of writing NULL" do
        assert_raise Ecto.InvalidChangesetError, fn ->
          LegacyBridgeTransfer.upsert_all([Map.put(row(:withdrawal, 7, 100), :migrated_msg_data, "not hex")])
        end

        assert Repo.all(LegacyBridgeTransfer) == []
      end
    end

    defp row(direction, nonce, amount) do
      %{
        direction: direction,
        nonce: Decimal.new(nonce),
        transaction_hash: transaction_hash(),
        block_number: 10,
        timestamp: DateTime.utc_now(),
        transfer_type: :eth,
        transfer_from_address_hash: address_hash(),
        transfer_to_address_hash: address_hash(),
        transfer_amount: Decimal.new(amount),
        message_hash: transaction_hash()
      }
    end
  end
end
