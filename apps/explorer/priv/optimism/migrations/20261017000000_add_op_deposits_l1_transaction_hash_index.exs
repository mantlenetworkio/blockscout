defmodule Explorer.Repo.Optimism.Migrations.AddOpDepositsL1TransactionHashIndex do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # An interrupted concurrent build leaves an invalid index behind, which `create_if_not_exists` would skip on the
  # retry. Dropping it first makes the retry build the index again.
  def up do
    drop_if_exists(l1_transaction_hash_index())
    create(l1_transaction_hash_index())
  end

  def down do
    drop_if_exists(l1_transaction_hash_index())
  end

  # The bridge looks deposits up by their L1 transaction while it waits for them to be indexed
  defp l1_transaction_hash_index do
    index(:op_deposits, [:l1_transaction_hash], name: :op_deposits_l1_transaction_hash_index, concurrently: true)
  end
end
