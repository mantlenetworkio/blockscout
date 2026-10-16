defmodule Explorer.Repo.Optimism.Migrations.AddOpDepositsOriginIndex do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # An interrupted concurrent build leaves an invalid index behind, which `create_if_not_exists` would skip on the
  # retry. Dropping it first makes the retry build the index again.
  def up do
    drop_if_exists(origin_index())
    create(origin_index())
  end

  def down do
    drop_if_exists(origin_index())
  end

  defp origin_index do
    index(:op_deposits, [:l1_transaction_origin, :l1_block_number, :l2_transaction_hash],
      name: :op_deposits_l1_transaction_origin_index,
      concurrently: true
    )
  end
end
