defmodule Explorer.Repo.Optimism.Migrations.CreateMantleLegacyBridgeTransfers do
  use Ecto.Migration

  # Mantle v1 (pre-Bedrock) bridge messages, rebuilt from chain data by Indexer.Fetcher.Optimism.LegacyBridge. The table
  # starts empty, so its indexes are built in the same transaction.
  def change do
    execute(
      "CREATE TYPE op_bridge_direction AS ENUM ('deposit', 'withdrawal')",
      "DROP TYPE op_bridge_direction"
    )

    create table(:mantle_legacy_bridge_transfers, primary_key: false) do
      add(:direction, :op_bridge_direction, null: false, primary_key: true)
      add(:nonce, :numeric, precision: 100, null: false, primary_key: true)
      add(:transaction_hash, :bytea, null: false)
      add(:block_number, :bigint, null: false)
      add(:timestamp, :utc_datetime_usec, null: true)
      add(:transfer_type, :op_bridge_transfer_type, null: false)
      add(:transfer_from_address_hash, :bytea, null: true)
      add(:transfer_to_address_hash, :bytea, null: true)
      add(:l1_token_address_hash, :bytea, null: true)
      add(:l2_token_address_hash, :bytea, null: true)
      add(:transfer_amount, :numeric, precision: 100, null: true)
      add(:message_hash, :bytea, null: false)
      add(:migrated_withdrawal_hash, :bytea, null: true)
      add(:migrated_message_hash, :bytea, null: true)
      add(:migrated_msg_data, :bytea, null: true)
      add(:migrated_gas_limit, :numeric, precision: 100, null: true)

      timestamps(null: false, type: :utc_datetime_usec)
    end

    # One index range per side of an address page, in the order the bridge history pages through it
    for side <- [:from, :to] do
      column = :"transfer_#{side}_address_hash"

      create(
        index(:mantle_legacy_bridge_transfers, [column, :block_number, :message_hash],
          name: :"mantle_legacy_bridge_deposits_#{side}_index",
          where: "direction = 'deposit'"
        )
      )

      create(
        index(:mantle_legacy_bridge_transfers, [column, :nonce],
          name: :"mantle_legacy_bridge_withdrawals_#{side}_index",
          where: "direction = 'withdrawal'"
        )
      )
    end

    create(index(:mantle_legacy_bridge_transfers, [:transaction_hash]))
    create(index(:mantle_legacy_bridge_transfers, [:message_hash]))
    create(index(:mantle_legacy_bridge_transfers, [:migrated_withdrawal_hash]))
  end
end
