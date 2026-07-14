defmodule Explorer.Chain.Import.Runner.ScaledUiMultiplierUpdatesTest do
  use Explorer.DataCase

  alias Ecto.Multi
  alias Explorer.Chain.Import.Runner.ScaledUiMultiplierUpdates
  alias Explorer.Chain.ScaledUiMultiplierUpdate
  alias Explorer.Repo

  describe "run/3" do
    test "imports both event shapes idempotently" do
      token_address = insert(:contract_address)
      transaction = insert(:transaction) |> with_block()
      block = transaction.block

      changes_list = [
        %{
          token_contract_address_hash: token_address.hash,
          transaction_hash: transaction.hash,
          block_hash: block.hash,
          block_number: block.number,
          block_timestamp: Decimal.new(DateTime.to_unix(block.timestamp)),
          log_index: 3,
          event_type: "updated",
          old_multiplier: Decimal.new(0),
          new_multiplier: Decimal.new("1000000000000000000"),
          effective_at: Decimal.new(DateTime.to_unix(block.timestamp))
        },
        %{
          token_contract_address_hash: token_address.hash,
          transaction_hash: transaction.hash,
          block_hash: block.hash,
          block_number: block.number,
          block_timestamp: Decimal.new(DateTime.to_unix(block.timestamp)),
          log_index: 4,
          event_type: "overwritten",
          new_multiplier: Decimal.new("3000000000000000000"),
          effective_at: Decimal.new(DateTime.to_unix(block.timestamp) + 200),
          overwritten_multiplier: Decimal.new("2000000000000000000"),
          overwritten_effective_at: Decimal.new(DateTime.to_unix(block.timestamp) + 100)
        }
      ]

      options = %{timestamps: Explorer.Chain.Import.timestamps()}

      assert {:ok, %{scaled_ui_multiplier_updates: first_insert}} = run(changes_list, options)
      assert length(first_insert) == 2

      assert {:ok, %{scaled_ui_multiplier_updates: []}} = run(changes_list, options)
      assert Repo.aggregate(ScaledUiMultiplierUpdate, :count) == 2

      assert Enum.sort(Repo.all(ScaledUiMultiplierUpdate) |> Enum.map(& &1.event_type)) == [
               "overwritten",
               "updated"
             ]
    end
  end

  defp run(changes_list, options) do
    Multi.new()
    |> ScaledUiMultiplierUpdates.run(changes_list, options)
    |> Repo.transaction()
  end
end
