defmodule Explorer.Repo.Optimism.Migrations.AddOpMessageRelaysTable do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TYPE op_message_relay_event_type AS ENUM ('RelayedMessage', 'FailedRelayedMessage')",
      "DROP TYPE op_message_relay_event_type"
    )

    execute(
      "CREATE TYPE op_message_relay_chain AS ENUM ('l1', 'l2')",
      "DROP TYPE op_message_relay_chain"
    )

    create table(:op_message_relays, primary_key: false) do
      add(:message_hash, :bytea, null: false, primary_key: true)
      add(:event_type, :op_message_relay_event_type, null: false, primary_key: true)
      add(:transaction_hash, :bytea, null: false, primary_key: true)
      add(:chain, :op_message_relay_chain, null: false)
      add(:block_number, :bigint, null: false)

      timestamps(null: false, type: :utc_datetime_usec)
    end

    create(index(:op_message_relays, [:chain, :block_number]))
  end
end
