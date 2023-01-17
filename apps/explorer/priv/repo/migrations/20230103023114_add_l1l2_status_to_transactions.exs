defmodule Explorer.Repo.Migrations.AddL1l2StatusToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add(:l1l2_l1_token, :bytea, null: true)
      add(:l1l2_l2_token, :bytea, null: true)
      add(:l1l2_status, :integer, null: false, default: 0)  # 0: wait transaction; 1: ready for Relay transaction; 2: Relayed transaction
      add(:l1l2_type, :integer, null: false, default: 0)    # 0: normal transaction; 1: deposit transaction; 2: withdraw; 3:reward
      add(:l1l2_from, :bytea, null: true)
      add(:l1l2_to, :bytea, null: true)
      add(:l1l2_value, :numeric, precision: 100, null: false, default: 0)
    end
  end
end
