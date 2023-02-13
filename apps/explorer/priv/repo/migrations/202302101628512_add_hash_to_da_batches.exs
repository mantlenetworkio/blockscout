defmodule Explorer.Repo.Migrations.AddHashToDaBatches do
  use Ecto.Migration

  def change do
    alter table(:da_batches) do
      add(:da_init_hash, :bytea, null: false)
      add(:da_store_hash, :bytea, null: false)
      add(:from_store_number, :int8, null: false)
    end
  end
end
