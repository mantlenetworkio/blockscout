defmodule Explorer.Repo.Migrations.AddArsiaFeeFieldsToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add(:operator_fee_scalar, :numeric, precision: 100, null: true)
      add(:operator_fee_constant, :numeric, precision: 100, null: true)
      add(:da_footprint_gas_scalar, :numeric, precision: 100, null: true)
    end
  end
end
