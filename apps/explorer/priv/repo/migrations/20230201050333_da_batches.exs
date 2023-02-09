defmodule Explorer.Repo.Migrations.DaBatches do
  use Ecto.Migration

  def change do
    create table(:da_batches, primary_key: false) do
      add(:batch_index, :bigint, null: false)
      add(:batch_size, :bigint, null: false)
      add(:status, :string, null: false)  # init, confirmed, fraud
      add(:start_block, :bigint, null: false)
      add(:end_block, :bigint, null: false)
      add(:da_hash, :bytea, null: false, primary_key: true)
      add(:store_id, :bigint, null: false)
      add(:store_number, :bigint, null: false)
      add(:da_fee, :numeric, precision: 100, null: false)
      timestamps(null: false, type: :utc_datetime_usec)
    end
    create(unique_index(:da_batches, [:batch_index]))
  end
end
