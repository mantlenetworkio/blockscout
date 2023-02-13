defmodule Explorer.Repo.Migrations.UpdateBlockNumberToBatchTx do
  use Ecto.Migration

  def change do
    alter table(:da_batches) do
      remove(:start_block)
      remove(:end_block)
    end

    alter table(:da_batch_transactions) do
      add(:block_number, :bigint, null: false)
    end
  end
end
