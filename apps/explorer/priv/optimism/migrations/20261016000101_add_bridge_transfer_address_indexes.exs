defmodule Explorer.Repo.Optimism.Migrations.AddBridgeTransferAddressIndexes do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # An interrupted concurrent build leaves an invalid index behind, which `create_if_not_exists` would skip on the
  # retry. Dropping it first makes the retry build the index again.
  def up do
    for index <- indexes() do
      drop_if_exists(index)
      create(index)
    end
  end

  def down do
    for index <- indexes(), do: drop_if_exists(index)
  end

  # Each index serves one side of an address page in the order the page reads: deposits by L1 block and L2 hash,
  # withdrawals by nonce.
  defp indexes do
    Enum.flat_map([:from, :to], fn side ->
      column = :"transfer_#{side}_address_hash"

      [
        index(:op_deposits, [column, :l1_block_number, :l2_transaction_hash],
          name: :"op_deposits_transfer_#{side}_index",
          concurrently: true
        ),
        index(:op_withdrawals, [column, :msg_nonce], name: :"op_withdrawals_transfer_#{side}_index", concurrently: true)
      ]
    end)
  end
end
