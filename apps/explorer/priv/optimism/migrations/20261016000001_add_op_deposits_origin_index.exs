defmodule Explorer.Repo.Optimism.Migrations.AddOpDepositsOriginIndex do
  use Ecto.Migration

  # A plain build, not a concurrent one. It locks op_deposits against writes, for the seconds a table this size takes.
  # A concurrent build would also wait for every older transaction in the database to end, which a long-running query
  # on another table stretches past the deploy's startup window. An index that an interrupted concurrent build of an
  # earlier version left behind is dropped first, and only then is the table locked against reads too, until the
  # migration commits.
  def up do
    drop_if_exists(origin_index())
    create(origin_index())
  end

  def down do
    drop_if_exists(origin_index())
  end

  defp origin_index do
    index(:op_deposits, [:l1_transaction_origin, :l1_block_number, :l2_transaction_hash],
      name: :op_deposits_l1_transaction_origin_index
    )
  end
end
