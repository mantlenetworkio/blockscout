defmodule Explorer.Repo.Optimism.Migrations.AddBridgeTransferAddressIndexes do
  use Ecto.Migration

  # Plain builds, not concurrent ones. They lock op_deposits and op_withdrawals against writes, for the seconds tables
  # this size take. A concurrent build would also wait for every older transaction in the database to end, which a
  # long-running query on another table stretches past the deploy's startup window. Indexes that an interrupted
  # concurrent build of an earlier version left behind are dropped first, and only then is their table locked against
  # reads too, until the migration commits. Dropping them all before building any takes each table's strongest lock
  # first, rather than upgrading a lock already held.
  def up do
    for index <- indexes(), do: drop_if_exists(index)
    for index <- indexes(), do: create(index)
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
          name: :"op_deposits_transfer_#{side}_index"
        ),
        index(:op_withdrawals, [column, :msg_nonce], name: :"op_withdrawals_transfer_#{side}_index")
      ]
    end)
  end
end
