defmodule Explorer.Repo.Migrations.DropDaIndex do
  use Ecto.Migration

  def change do
    drop(unique_index(:da_batches, [:batch_index]))
    drop(unique_index(:da_batch_transactions, [:batch_index]))
  end
end
