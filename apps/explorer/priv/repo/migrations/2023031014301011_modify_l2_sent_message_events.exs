defmodule Explorer.Repo.Migrations.ModifyL2SentMessageEvents do
  use Ecto.Migration

  def change do
    alter table(:l2_sent_message_events) do
      modify(:tx_hash, :bytea, null: true)
      modify(:block_number, :bigint, null: true)
      modify(:target, :bytea, null: true)
      modify(:sender, :bytea, null: true)
      modify(:message, :bytea, null: true)
      modify(:gas_limit, :numeric, precision: 100, null: true)
      modify(:signature, :bytea, null: true)
      modify(:timestamp, :utc_datetime_usec, null: true)
      modify(:is_merge, :boolean, null: true, default: false)
      modify(:value, :numeric, precision: 100, null: true, default: 0)
      modify(:inserted_at, :utc_datetime_usec, null: true)
      modify(:updated_at, :utc_datetime_usec, null: true)
    end
  end
end
