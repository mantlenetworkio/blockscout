defmodule Explorer.Repo.Migrations.AddL2MessageToL2SentMessageEvents do
  use Ecto.Migration

  def change do
     alter table(:l2_sent_message_events) do
      add(:l1_token, :bytea, null: true)
      add(:l2_token, :bytea, null: true)
      add(:from, :bytea, null: true)
      add(:to, :bytea, null: true)
      add(:value, :numeric, precision: 100, null: false, default: 0)
    end
  end
end
