defmodule Explorer.Repo.Migrations.AddL1MessageToL1SentMessageEvents do
  use Ecto.Migration

  def change do
    alter table(:l1_sent_message_events) do
      add(:l1_token, :bytea, null: true)
      add(:l2_token, :bytea, null: true)
      add(:from, :bytea, null: true)
      add(:to, :bytea, null: true)
      add(:type, :integer, null: false, default: 0)    # 0: reward; 1: deposit
      add(:value, :numeric, precision: 100, null: false, default: 0)
    end
  end
end
