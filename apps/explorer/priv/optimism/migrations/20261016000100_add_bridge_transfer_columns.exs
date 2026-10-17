defmodule Explorer.Repo.Optimism.Migrations.AddBridgeTransferColumns do
  use Ecto.Migration

  # Nullable columns without defaults: adding them does not rewrite either table.
  def change do
    execute(
      "CREATE TYPE op_bridge_transfer_type AS ENUM ('eth', 'mnt', 'erc20', 'message')",
      "DROP TYPE op_bridge_transfer_type"
    )

    for table <- [:op_deposits, :op_withdrawals] do
      alter table(table) do
        add(:message_hash, :bytea, null: true)
        add(:transfer_type, :op_bridge_transfer_type, null: true)
        add(:transfer_from_address_hash, :bytea, null: true)
        add(:transfer_to_address_hash, :bytea, null: true)
        add(:l1_token_address_hash, :bytea, null: true)
        add(:l2_token_address_hash, :bytea, null: true)
        add(:transfer_amount, :numeric, precision: 100, null: true)
        add(:mnt_value, :numeric, precision: 100, null: true)
        add(:eth_value, :numeric, precision: 100, null: true)
      end
    end
  end
end
