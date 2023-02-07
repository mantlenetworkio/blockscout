defmodule Explorer.Repo.Migrations.DaBatchTransactions do
  use Ecto.Migration

  def change do
     create table(:da_batch_transactions, primary_key: false) do
      add(:batch_index, :bigint, null: false)
      add(:tx_hash, :string, null: false, primary_key: true)
      #timestamps(null: false, type: :utc_datetime_usec)
    end
    create(unique_index(:da_batch_transactions, [:batch_index]))
  end
end
