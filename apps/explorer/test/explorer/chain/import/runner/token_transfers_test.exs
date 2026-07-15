defmodule Explorer.Chain.Import.Runner.TokenTransfersTest do
  use Explorer.DataCase

  alias Ecto.Multi
  alias Explorer.Chain.Import.Runner.TokenTransfers
  alias Explorer.Chain.TokenTransfer
  alias Explorer.Repo

  describe "run/3" do
    test "updates scaled UI fields when a transfer already exists" do
      transaction = insert(:transaction) |> with_block()

      transfer =
        insert(:token_transfer,
          transaction: transaction,
          ui_value: nil,
          ui_multiplier: nil,
          ui_amount_status: "unknown"
        )

      changes =
        transfer
        |> Map.from_struct()
        |> Map.take([
          :amount,
          :block_consensus,
          :block_hash,
          :block_number,
          :from_address_hash,
          :log_index,
          :to_address_hash,
          :token_contract_address_hash,
          :token_ids,
          :token_type,
          :transaction_hash
        ])
        |> Map.merge(%{
          ui_value: Decimal.new("3672865380000000000"),
          ui_multiplier: Decimal.new("1000000000000000000"),
          ui_amount_status: "ok"
        })

      assert {:ok, %{token_transfers: [_]}} = run_changes(changes)

      reloaded =
        Repo.get_by!(TokenTransfer,
          block_hash: transfer.block_hash,
          log_index: transfer.log_index
        )

      assert reloaded.ui_value == Decimal.new("3672865380000000000")
      assert reloaded.ui_multiplier == Decimal.new("1000000000000000000")
      assert reloaded.ui_amount_status == "ok"
    end
  end

  defp run_changes(changes) do
    Multi.new()
    |> TokenTransfers.run([changes], %{
      timestamps: %{inserted_at: DateTime.utc_now(), updated_at: DateTime.utc_now()}
    })
    |> Repo.transaction()
  end
end
